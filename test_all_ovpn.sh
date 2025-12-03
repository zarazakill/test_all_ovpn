#!/bin/bash

WORK_DIR="/tmp/vpngate_test_$$"
OUTPUT_DIR="$HOME/Загрузки/vpngate_working"
VPNGATE_URL="https://download.vpngate.jp/api/iphone/"
AUTH_LOGIN="vpn"
AUTH_PASS="vpn"

# Зависимости
for cmd in curl openvpn ip base64; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ Требуется: $cmd"
        exit 1
    fi
done

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR" || exit 1

echo "📥 Загрузка CSV..."
curl -s "$VPNGATE_URL" -o servers.csv

# Проверяем, является ли файл CSV или HTML
if grep -q "<" servers.csv; then
    echo "❌ Получен HTML-файл вместо CSV. API VPN Gate, возможно, больше не доступен."
    echo "❌ Проверьте https://www.vpngate.net/ для получения актуальной информации."
    echo "=== Первые 3 строки файла ==="
    head -n 3 servers.csv
    echo "=== Последние 3 строки файла ==="
    tail -n 3 servers.csv
    echo "==========================="
    exit 1
fi

# Проверяем формат файла
echo "=== Первые 3 строки CSV ==="
head -n 3 servers.csv
echo "=== Последние 3 строки CSV ==="
tail -n 3 servers.csv
echo "==========================="

# Пропускаем заголовок (обычно 2 строки)
tail -n +3 servers.csv > data.csv

if [ ! -s data.csv ]; then
    echo "❌ CSV пуст"
    exit 1
fi

TOTAL=$(wc -l < data.csv)
echo "Найдено $TOTAL строк. Извлечение base64..."

# Создаем auth.txt сразу
echo -e "${AUTH_LOGIN}\n${AUTH_PASS}" > auth.txt

# Более надежный парсинг CSV
LINE_NUM=0
OVPN_COUNT=0

# Проанализируем структуру CSV
echo "Анализ структуры CSV..."
head -n 1 data.csv | awk -F',' '{print "Количество полей: " NF}'

while IFS= read -r line; do
    ((LINE_NUM++))
    
    # Удаляем Windows-символы
    line=$(echo "$line" | tr -d '\r')
    [ -z "$line" ] && continue
    
    # Используем awk для более надежного парсинга
    IP=$(echo "$line" | awk -F',' '{print $2}')
    BASE64_FIELD=$(echo "$line" | awk -F',' '{print $NF}')  # Последнее поле
    
    # Убираем ВСЕ кавычки
    BASE64_FIELD=$(echo "$BASE64_FIELD" | sed 's/^"//g; s/"$//g; s/\"//g')
    
    # Проверяем, что это похоже на base64
    if [[ ${#BASE64_FIELD} -gt 200 ]] && [[ "$BASE64_FIELD" != "0" ]]; then
        
        # Декодируем и проверяем
        DECODED=$(echo "$BASE64_FIELD" | base64 -d 2>/dev/null)
        if echo "$DECODED" | grep -q "client\|remote"; then
            FILENAME="vpngate_${IP:-unknown_$LINE_NUM}.ovpn"
            
            # Сохраняем декодированные данные
            echo "$DECODED" > "$FILENAME"
            
            if [ -s "$FILENAME" ]; then
                # Добавляем auth-user-pass если нет
                if ! grep -q "auth-user-pass" "$FILENAME"; then
                    echo "" >> "$FILENAME"
                    echo "auth-user-pass auth.txt" >> "$FILENAME"
                fi
                
                # Добавляем дополнительные настройки для надежности
                if ! grep -q "persist-key" "$FILENAME"; then
                    echo "persist-key" >> "$FILENAME"
                fi
                if ! grep -q "persist-tun" "$FILENAME"; then
                    echo "persist-tun" >> "$FILENAME"
                fi
                if ! grep -q "nobind" "$FILENAME"; then
                    echo "nobind" >> "$FILENAME"
                fi
                
                ((OVPN_COUNT++))
                echo "✓ Создан: $FILENAME (длина base64: ${#BASE64_FIELD})"
            else
                rm -f "$FILENAME" 2>/dev/null
            fi
        else
            echo "✗ Строка $LINE_NUM: не содержит client/remote директив"
        fi
    else
        echo "✗ Строка $LINE_NUM: слишком короткая или '0' (длина: ${#BASE64_FIELD})"
    fi
done < data.csv

echo "Создано $OVPN_COUNT .ovpn файлов."

if [ "$OVPN_COUNT" -eq 0 ]; then
    echo "❌ Не создано ни одного .ovpn файла."
    echo "Проверьте формат CSV. Возможно, изменилась структура."
    
    # Покажем пример строки для отладки
    echo "=== Пример строки CSV ==="
    head -n 1 data.csv
    echo "=== Последнее поле ==="
    head -n 1 data.csv | awk -F',' '{print $NF}' | head -c 100
    echo "..."
    exit 1
fi

# Проверка текущего IP
echo "Проверка текущего IP..."
ORIGINAL_IP=$(timeout 10 curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "неизвестен")
echo "Текущий IP: $ORIGINAL_IP"

# Функция для диагностики с использованием Python
# Функция для диагностики с использованием Python
diagnose_ovpn() {
    local config="$1"
    local log_file="./logs/vpngate_diagnose_$$.log"
    mkdir -p ./logs
    
    python3 ./diagnose_vpn.py "$config"
    return $?
}

# Основная функция тестирования с расширенной диагностикой
test_ovpn_with_diagnosis() {
    local config="$1"
    local config_name=$(basename "$config")
    local pid_file="./logs/vpngate_${config_name}_pid"
    local log_file="./logs/vpngate_${config_name}_log"
    mkdir -p ./logs
    
    echo -n "Тест $config_name ... "
    
    # Проверяем файл конфигурации
    if [ ! -s "$config" ]; then
        echo "❌ пустой файл"
        return 1
    fi
    
    # Проверяем необходимые директивы
    if ! grep -q "remote " "$config"; then
        echo "❌ нет remote директивы"
        return 1
    fi
    
    # Извлекаем информацию о сервере
    REMOTE_LINE=$(grep "remote " "$config" | head -1)
    SERVER=$(echo "$REMOTE_LINE" | awk '{print $2}')
    PORT=$(echo "$REMOTE_LINE" | awk '{print $3}')
    PORT=${PORT:-1194}
    
    # Проверяем доступность сервера (только если не Japan)
    if [[ ! "$SERVER" =~ \.jp$ ]] && [[ "$SERVER" != "unknown"* ]]; then
        if ! timeout 3 nc -z "$SERVER" "$PORT" 2>/dev/null; then
            echo "❌ сервер $SERVER:$PORT недоступен"
            return 1
        fi
    fi
    
    # Запускаем OpenVPN с расширенным логом
    sudo openvpn \
        --config "$config" \
        --daemon \
        --writepid "$pid_file" \
        --log "$log_file" \
        --verb 3 \
        --connect-timeout 25 \
        --auth-retry interact
    
    # Ждем подключения
    CONNECTED=0
    for i in {1..40}; do
        if grep -q "Initialization Sequence Completed" "$log_file" 2>/dev/null; then
            CONNECTED=1
            break
        fi
        sleep 1
    done
    
    if [ $CONNECTED -eq 1 ]; then
        # Проверяем IP
        sleep 3
        NEW_IP=$(timeout 10 curl -s --max-time 8 https://api.ipify.org 2>/dev/null)
        
        if [ -n "$NEW_IP" ] && [ "$NEW_IP" != "$ORIGINAL_IP" ]; then
            echo "✅ РАБОТАЕТ (IP: $NEW_IP)"
            # Копируем успешную конфигурацию
            cp "$config" "$OUTPUT_DIR/"
            
            # Сохраняем информацию о сервере
            echo "$config_name - $SERVER:$PORT - $NEW_IP" >> "$OUTPUT_DIR/success.txt"
            return 0
        else
            echo "⚠️  подключено, но IP не изменился"
        fi
    else
        # Анализируем ошибку
        if [ -f "$log_file" ]; then
            ERROR_TYPE="неизвестная ошибка"
            if grep -q "AUTH_FAILED" "$log_file"; then
                ERROR_TYPE="ошибка аутентификации"
            elif grep -q "TLS Error" "$log_file"; then
                ERROR_TYPE="ошибка TLS"
            elif grep -q "Connection refused" "$log_file"; then
                ERROR_TYPE="сервер недоступен"
            elif grep -q "No route to host" "$log_file"; then
                ERROR_TYPE="нет маршрута"
            fi
            echo "❌ $ERROR_TYPE"
        else
            echo "❌ не удалось подключиться"
        fi
    fi
    
    # Останавливаем OpenVPN
    if [ -f "$pid_file" ]; then
        sudo kill $(cat "$pid_file") 2>/dev/null
    fi
    sudo pkill -f "openvpn.*$config_name" 2>/dev/null
    
    # Удаляем временные файлы
    rm -f "$pid_file" "$log_file"
    
    return 1
}

# Тестируем все конфигурации
echo "Тестируем все $OVPN_COUNT конфигураций..."
WORKING=0
TESTED=0
FAILED=0

# Сортируем файлы по размеру (сначала самые большие)
for f in $(ls -S *.ovpn 2>/dev/null); do
    if [ -f "$f" ]; then
        ((TESTED++))
        
        if test_ovpn_with_diagnosis "$f"; then
            ((WORKING++))
            # Если нашли 5 рабочих, можно ускорить процесс
            if [ "$WORKING" -ge 5 ]; then
                echo "Найдено достаточно рабочих конфигураций"
                break
            fi
        else
            ((FAILED++))
        fi
        
        echo "Прогресс: $TESTED/$OVPN_COUNT (рабочих: $WORKING)"
    fi
done

# Копируем auth.txt
cp auth.txt "$OUTPUT_DIR/" 2>/dev/null

# Создаем итоговый отчет
echo ""
echo "========================================"
echo "ИТОГОВЫЙ ОТЧЕТ"
echo "========================================"
echo "Всего конфигураций: $OVPN_COUNT"
echo "Протестировано: $TESTED"
echo "Рабочих: $WORKING"
echo "Не рабочих: $FAILED"
echo "Успешные конфигурации сохранены в: $OUTPUT_DIR"
echo ""

if [ "$WORKING" -gt 0 ]; then
    echo "✅ Найдено рабочих конфигураций:"
    if [ -f "$OUTPUT_DIR/success.txt" ]; then
        cat "$OUTPUT_DIR/success.txt"
    fi
    
    # Создаем скрипт для быстрого запуска
    cat > "$OUTPUT_DIR/start_vpn.sh" << 'EOF'
#!/bin/bash
echo "Доступные VPN конфигурации:"
ls *.ovpn | cat -n
echo -n "Выберите номер: "
read num
config=$(ls *.ovpn | sed -n "${num}p")
if [ -f "$config" ]; then
    echo "Запуск $config..."
    sudo openvpn --config "$config"
else
    echo "Неверный номер"
fi
EOF
    chmod +x "$OUTPUT_DIR/start_vpn.sh"
    echo "Для запуска используйте: $OUTPUT_DIR/start_vpn.sh"
else
    echo "❌ Рабочих конфигураций не найдено"
    echo ""
    echo "ВОЗМОЖНЫЕ ПРИЧИНЫ:"
    echo "1. Серверы VPN Gate временно недоступны"
    echo "2. Изменился формат API"
    echo "3. Проблемы с сетью или брандмауэром"
    echo "4. Учетные данные vpn/vpn больше не работают"
    echo ""
    echo "РЕКОМЕНДАЦИИ:"
    echo "1. Проверьте https://www.vpngate.net/"
    echo "2. Попробуйте вручную подключиться к одному из файлов"
    echo "3. Проверьте логи в ./logs/vpngate_*_log"
fi

echo "========================================"

# Очистка
rm -rf "$WORK_DIR"
