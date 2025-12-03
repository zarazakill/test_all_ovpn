#!/bin/bash

WORK_DIR="/tmp/vpngate_test_$$"
OUTPUT_DIR="$HOME/Загрузки/vpngate_working"
VPNGATE_URL="https://download.vpngate.jp/api/iphone/"
ALTERNATE_URL="https://www.vpngate.net/api/iphone/"
AUTH_LOGIN="vpn"
AUTH_PASS="vpn"

# Функция для вывода сообщений с меткой времени
log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# Функция для исправления inline сертификатов в конфигурации
fix_inline_certs() {
    local config_file="$1"
    local temp_file="${config_file}.tmp"
    
    # Проверяем, есть ли inline данные
    if grep -q "<cert>" "$config_file" && grep -q "</cert>" "$config_file"; then
        log "  Исправление inline сертификатов..."
        
        # Создаем временный файл для исправленной конфигурации
        > "$temp_file"
        
        # Обрабатываем файл построчно
        while IFS= read -r line; do
            # Если находим открывающий тег cert/key/ca, начинаем извлечение
            if [[ "$line" =~ ^\<(cert|key|ca)\>$ ]]; then
                tag="${BASH_REMATCH[1]}"
                content=""
                
                # Читаем содержимое до закрывающего тега
                while IFS= read -r inner_line; do
                    if [[ "$inner_line" =~ ^\</$tag\>$ ]]; then
                        break
                    fi
                    content+="$inner_line"$'\n'
                done
                
                # Пишем правильный формат PEM
                echo "<$tag>" >> "$temp_file"
                echo "-----BEGIN ${tag^^}-----" >> "$temp_file"
                # Убираем лишние пробелы и разбиваем на строки по 64 символа
                echo "$content" | tr -d '\r' | sed '/^$/d' | fold -w 64 >> "$temp_file"
                echo "-----END ${tag^^}-----" >> "$temp_file"
                echo "</$tag>" >> "$temp_file"
            else
                echo "$line" >> "$temp_file"
            fi
        done < "$config_file"
        
        # Заменяем оригинальный файл
        mv "$temp_file" "$config_file"
        return 0
    fi
    
    # Если нет inline тегов, но есть длинные base64 строки, возможно, это неправильно оформленные сертификаты
    if grep -q "BEGIN CERTIFICATE" "$config_file" && ! grep -q "-----BEGIN CERTIFICATE-----" "$config_file"; then
        log "  Исправление PEM формата..."
        sed -i 's/BEGIN CERTIFICATE/-----BEGIN CERTIFICATE-----/g' "$config_file"
        sed -i 's/END CERTIFICATE/-----END CERTIFICATE-----/g' "$config_file"
        sed -i 's/BEGIN PRIVATE KEY/-----BEGIN PRIVATE KEY-----/g' "$config_file"
        sed -i 's/END PRIVATE KEY/-----END PRIVATE KEY-----/g' "$config_file"
        sed -i 's/BEGIN RSA PRIVATE KEY/-----BEGIN RSA PRIVATE KEY-----/g' "$config_file"
        sed -i 's/END RSA PRIVATE KEY/-----END RSA PRIVATE KEY-----/g' "$config_file"
    fi
    
    return 0
}

# Функция для стандартизации конфигурации
standardize_config() {
    local config_file="$1"
    
    # 1. Удаляем BOM маркер если есть
    sed -i '1s/^\xEF\xBB\xBF//' "$config_file" 2>/dev/null
    
    # 2. Преобразуем Windows концы строк
    dos2unix -q "$config_file" 2>/dev/null || tr -d '\r' < "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
    
    # 3. Исправляем inline сертификаты
    fix_inline_certs "$config_file"
    
    # 4. Добавляем auth-user-pass если нет
    if ! grep -q "^auth-user-pass" "$config_file"; then
        echo "" >> "$config_file"
        echo "auth-user-pass auth.txt" >> "$config_file"
    fi
    
    # 5. Добавляем стандартные параметры
    STANDARD_OPTS=(
        "client"
        "dev tun"
        "proto udp"
        "resolv-retry infinite"
        "nobind"
        "persist-key"
        "persist-tun"
        "remote-cert-tls server"
        "cipher AES-256-CBC"
        "auth SHA256"
        "verb 3"
        "mute 20"
        "keepalive 10 30"
    )
    
    for opt in "${STANDARD_OPTS[@]}"; do
        if ! grep -q "^${opt}" "$config_file"; then
            echo "$opt" >> "$config_file"
        fi
    done
    
    # 6. Удаляем дубликаты и пустые строки
    awk '!seen[$0]++ && NF' "$config_file" > "${config_file}.tmp"
    mv "${config_file}.tmp" "$config_file"
    
    return 0
}

# Проверка зависимостей
log "Проверка зависимостей..."
for cmd in curl openvpn ip base64; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ Требуется: $cmd"
        exit 1
    fi
done

# Проверка дополнительных зависимостей
for cmd in dos2unix fold; do
    if ! command -v "$cmd" &>/dev/null; then
        log "⚠️  Установите $cmd для лучшей обработки файлов"
        log "  Ubuntu/Debian: sudo apt install $cmd"
        log "  CentOS/RHEL: sudo yum install $cmd"
    fi
done

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR" || exit 1

# Функция для загрузки CSV
download_csv() {
    local url=$1
    local output=$2
    local attempt=1
    local max_attempts=3
    
    while [ $attempt -le $max_attempts ]; do
        log "Попытка $attempt/$max_attempts: загрузка с $url"
        
        curl -s --connect-timeout 30 --max-time 60 \
             -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
             "$url" -o "$output"
        
        # Проверяем результат
        if [ -f "$output" ] && [ -s "$output" ]; then
            if ! grep -q "<html\|<!DOCTYPE" "$output" 2>/dev/null; then
                log "✓ CSV успешно загружен ($(wc -l < "$output") строк)"
                return 0
            fi
        fi
        
        sleep 2
        ((attempt++))
    done
    
    return 1
}

# Пытаемся загрузить CSV
log "Загрузка списка серверов VPN Gate..."
if download_csv "$VPNGATE_URL" "servers.csv"; then
    log "Основной URL сработал"
elif download_csv "$ALTERNATE_URL" "servers.csv"; then
    log "Альтернативный URL сработал"
else
    log "❌ Не удалось загрузить CSV файл"
    echo "Проблемы с доступом к VPN Gate API"
    exit 1
fi

# Пропускаем заголовок (обычно 2 строки)
tail -n +3 servers.csv > data.csv 2>/dev/null

if [ ! -s data.csv ]; then
    cp servers.csv data.csv
fi

if [ ! -s data.csv ]; then
    log "❌ CSV пуст или содержит недостаточно данных"
    exit 1
fi

# Создаем auth.txt
echo -e "${AUTH_LOGIN}\n${AUTH_PASS}" > auth.txt

# Парсим CSV и создаем конфигурации
log "Парсинг CSV и создание .ovpn файлов..."
LINE_NUM=0
OVPN_COUNT=0

while IFS= read -r line || [ -n "$line" ]; do
    ((LINE_NUM++))
    
    # Удаляем Windows-символы
    line=$(echo "$line" | tr -d '\r')
    [ -z "$line" ] || [ "$line" = "*" ] && continue
    
    # Извлекаем IP (второе поле)
    IP=$(echo "$line" | awk -F',' '{print $2}' | sed 's/"//g')
    
    # Ищем поле с base64 (обычно последнее непустое поле)
    FIELD_COUNT=$(echo "$line" | awk -F',' '{print NF}')
    BASE64_FIELD=""
    
    # Ищем с конца
    for ((i=FIELD_COUNT; i>=1; i--)); do
        FIELD=$(echo "$line" | awk -F',' -v i="$i" '{print $i}' | sed 's/"//g')
        # Пропускаем пустые или короткие поля
        if [ -n "$FIELD" ] && [ "$FIELD" != "0" ] && [ ${#FIELD} -gt 100 ]; then
            BASE64_FIELD="$FIELD"
            break
        fi
    done
    
    if [ -z "$BASE64_FIELD" ]; then
        continue
    fi
    
    # Декодируем
    DECODED=$(echo "$BASE64_FIELD" | base64 -d 2>/dev/null)
    if [ $? -ne 0 ]; then
        continue
    fi
    
    # Проверяем, что это OpenVPN конфигурация
    if echo "$DECODED" | grep -q -i "openvpn\|client\|remote\|dev tun"; then
        FILENAME="vpngate_${IP:-server_$LINE_NUM}.ovpn"
        
        # Сохраняем сырую конфигурацию
        echo "$DECODED" > "$FILENAME"
        
        if [ -s "$FILENAME" ]; then
            # Стандартизируем конфигурацию
            standardize_config "$FILENAME"
            
            ((OVPN_COUNT++))
            echo "✓ Создан: $FILENAME"
        else
            rm -f "$FILENAME" 2>/dev/null
        fi
    fi
done < data.csv

log "Создано $OVPN_COUNT .ovpn файлов."

if [ "$OVPN_COUNT" -eq 0 ]; then
    log "❌ Не создано конфигураций"
    exit 1
fi

# Проверка текущего IP
log "Проверка текущего IP..."
ORIGINAL_IP=$(timeout 10 curl -s --max-time 8 https://api.ipify.org 2>/dev/null || \
              timeout 10 curl -s --max-time 8 https://icanhazip.com 2>/dev/null || \
              echo "неизвестен")
log "Текущий IP: $ORIGINAL_IP"

# Функция быстрой проверки конфигурации
quick_check_config() {
    local config="$1"
    
    # Проверяем обязательные секции
    local has_cert=$(grep -c "BEGIN CERTIFICATE\|<cert>" "$config")
    local has_key=$(grep -c "BEGIN PRIVATE KEY\|<key>" "$config")
    local has_ca=$(grep -c "BEGIN CERTIFICATE.*CA\|<ca>" "$config")
    local has_remote=$(grep -c "^remote " "$config")
    
    if [ "$has_remote" -eq 0 ]; then
        echo "❌ Нет remote директивы"
        return 1
    fi
    
    if [ "$has_cert" -eq 0 ] || [ "$has_key" -eq 0 ] || [ "$has_ca" -eq 0 ]; then
        echo "⚠️  Отсутствуют сертификаты/ключи"
        # Попробуем исправить
        standardize_config "$config"
    fi
    
    return 0
}

# Основная функция тестирования
test_ovpn_config() {
    local config="$1"
    local config_name=$(basename "$config")
    local pid_file="./logs/${config_name}.pid"
    local log_file="./logs/${config_name}.log"
    mkdir -p ./logs
    
    echo -n "Тест $config_name ... "
    
    # Быстрая проверка конфигурации
    if ! quick_check_config "$config"; then
        return 1
    fi
    
    # Извлекаем информацию о сервере
    REMOTE_LINE=$(grep "^remote " "$config" | head -1)
    SERVER=$(echo "$REMOTE_LINE" | awk '{print $2}')
    PORT=$(echo "$REMOTE_LINE" | awk '{print $3}')
    PORT=${PORT:-1194}
    
    # Запускаем OpenVPN
    sudo openvpn \
        --config "$config" \
        --daemon \
        --writepid "$pid_file" \
        --log "$log_file" \
        --verb 2 \
        --connect-timeout 30 \
        --auth-user-pass auth.txt
    
    # Ждем подключения
    CONNECTED=0
    for i in {1..30}; do
        if [ -f "$log_file" ] && grep -q "Initialization Sequence Completed" "$log_file" 2>/dev/null; then
            CONNECTED=1
            break
        fi
        
        # Проверяем на ошибки
        if [ -f "$log_file" ]; then
            if grep -q "AUTH_FAILED\|TLS Error\|Cannot load\|no start line" "$log_file"; then
                break
            fi
        fi
        
        sleep 1
        if [ $((i % 5)) -eq 0 ]; then echo -n "."; fi
    done
    
    if [ $CONNECTED -eq 1 ]; then
        sleep 2
        NEW_IP=$(timeout 5 curl -s --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '\n\r')
        
        if [ -n "$NEW_IP" ] && [ "$NEW_IP" != "$ORIGINAL_IP" ]; then
            echo "✅ РАБОТАЕТ (IP: $NEW_IP)"
            
            # Сохраняем рабочую конфигурацию
            cp "$config" "$OUTPUT_DIR/"
            echo "$config_name - $SERVER:$PORT - $NEW_IP" >> "$OUTPUT_DIR/success.txt"
            
            # Останавливаем OpenVPN
            if [ -f "$pid_file" ]; then
                sudo kill $(cat "$pid_file") 2>/dev/null
                sleep 1
            fi
            
            return 0
        else
            echo "⚠️  подключено, но IP: $NEW_IP"
        fi
    fi
    
    # Анализируем ошибку
    if [ -f "$log_file" ]; then
        ERROR_MSG=""
        if grep -q "Cannot load inline certificate" "$log_file"; then
            ERROR_MSG="проблема с сертификатами"
            # Пробуем пересоздать конфигурацию с правильными тегами
            echo "$DECODED" > "${config}.raw"
            fix_inline_certs "${config}.raw"
            cp "${config}.raw" "$config"
        elif grep -q "AUTH_FAILED" "$log_file"; then
            ERROR_MSG="ошибка аутентификации"
        elif grep -q "TLS Error" "$log_file"; then
            ERROR_MSG="ошибка TLS"
        elif grep -q "Connection refused" "$log_file"; then
            ERROR_MSG="сервер недоступен"
        elif grep -q "no start line" "$log_file"; then
            ERROR_MSG="неверный формат сертификата"
        else
            # Показываем последнюю строку ошибки
            ERROR_MSG=$(tail -n 3 "$log_file" | grep -i "error\|fail\|cannot" | tail -1 || echo "неизвестная ошибка")
        fi
        echo "❌ $ERROR_MSG"
    else
        echo "❌ не удалось подключиться"
    fi
    
    # Останавливаем OpenVPN
    if [ -f "$pid_file" ]; then
        sudo kill $(cat "$pid_file") 2>/dev/null
        sleep 1
    fi
    sudo pkill -f "openvpn.*$config_name" 2>/dev/null
    sleep 1
    
    rm -f "$pid_file" "$log_file" 2>/dev/null
    return 1
}

# Тестируем конфигурации
log "Тестируем конфигурации (первые 10)..."
WORKING=0
TESTED=0

# Берем только первые 10 для теста
for f in $(ls *.ovpn 2>/dev/null | head -10); do
    if [ -f "$f" ]; then
        ((TESTED++))
        
        if test_ovpn_config "$f"; then
            ((WORKING++))
            if [ "$WORKING" -ge 2 ]; then
                break
            fi
        fi
    fi
done

# Итоговый отчет
echo ""
echo "========================================"
echo "ИТОГОВЫЙ ОТЧЕТ"
echo "========================================"
echo "Создано конфигураций: $OVPN_COUNT"
echo "Протестировано: $TESTED"
echo "Рабочих: $WORKING"
echo ""

if [ "$WORKING" -gt 0 ]; then
    echo "✅ Найдено рабочих VPN серверов!"
    echo ""
    echo "Рабочие конфигурации в: $OUTPUT_DIR"
    
    # Создаем простой скрипт для запуска
    cat > "$OUTPUT_DIR/start_vpn.sh" << 'EOF'
#!/bin/bash
echo "Выберите VPN конфигурацию:"
ls *.ovpn | cat -n
echo -n "Номер: "
read num
config=$(ls *.ovpn | sed -n "${num}p")
if [ -f "$config" ]; then
    echo "Запуск: $config"
    sudo openvpn --config "$config"
else
    echo "Ошибка!"
fi
EOF
    chmod +x "$OUTPUT_DIR/start_vpn.sh"
    echo "Для запуска: cd \"$OUTPUT_DIR\" && sudo ./start_vpn.sh"
else
    echo "❌ Не найдено рабочих конфигураций"
    echo ""
    echo "СОВЕТЫ:"
    echo "1. VPN Gate может быть временно недоступен"
    echo "2. Попробуйте запустить скрипт позже"
    echo "3. Проверьте вручную: sudo openvpn --config любой.ovpn"
fi

echo "========================================"

# Сохраняем auth.txt
cp auth.txt "$OUTPUT_DIR/" 2>/dev/null

# Очистка
rm -rf "$WORK_DIR"
log "Готово!"
