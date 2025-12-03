#!/bin/bash

WORK_DIR="/tmp/vpngate_test_$$"
OUTPUT_DIR="/workspace/vpngate_working"
VPNGATE_URL="https://download.vpngate.jp/api/iphone/"
ALTERNATE_URL="https://www.vpngate.net/api/iphone/"
AUTH_LOGIN="vpn"
AUTH_PASS="vpn"

# Функция для вывода сообщений с меткой времени
log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# Функция для извлечения сертификатов из тегов и сохранения в отдельных файлах
extract_certs_to_files() {
    local config_file="$1"
    local temp_file="${config_file}.tmp"
    
    # Создаем директорию для сертификатов
    local cert_dir="${config_file%.ovpn}_certs"
    mkdir -p "$cert_dir"
    
    # Проверяем, есть ли inline данные в тегах
    if grep -q "<cert>" "$config_file" && grep -q "</cert>" "$config_file"; then
        log "  Извлечение сертификатов из тегов..."
        
        # Извлекаем клиентский сертификат
        sed -n '/<cert>/,/<\/cert>/p' "$config_file" | sed '1d;$d' > "$cert_dir/client.crt"
        
        # Извлекаем клиентский ключ
        sed -n '/<key>/,/<\/key>/p' "$config_file" | sed '1d;$d' > "$cert_dir/client.key"
        
        # Извлекаем CA сертификат
        sed -n '/<ca>/,/<\/ca>/p' "$config_file" | sed '1d;$d' > "$cert_dir/ca.crt"
        
        # Извлекаем TLS ключ если есть
        if grep -q "<tls-auth>" "$config_file"; then
            sed -n '/<tls-auth>/,/<\/tls-auth>/p' "$config_file" | sed '1d;$d' > "$cert_dir/ta.key"
        fi
        
        # Создаем новую конфигурацию с ссылками на файлы
        cat > "$temp_file" << EOF
client
dev tun
proto udp
remote $(grep "^remote" "$config_file" | head -1 | awk '{print $2, $3}')
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
verb 3
mute 20
keepalive 10 30

ca $cert_dir/ca.crt
cert $cert_dir/client.crt
key $cert_dir/client.key
auth-user-pass auth.txt
EOF
        
        # Добавляем tls-auth если был
        if [ -f "$cert_dir/ta.key" ]; then
            echo "tls-auth $cert_dir/ta.key 1" >> "$temp_file"
        fi
        
        # Заменяем оригинальный файл
        mv "$temp_file" "$config_file"
        return 0
    fi
    
    # Если нет тегов, проверяем обычные PEM блоки
    return 0
}

# Функция для преобразования inline сертификатов в отдельные файлы
convert_inline_certs() {
    local config_file="$1"
    local config_name=$(basename "$config_file")
    
    # Если в файле есть теги, извлекаем сертификаты
    if grep -q "<cert>" "$config_file"; then
        extract_certs_to_files "$config_file"
        return 0
    fi
    
    # Если есть inline PEM блоки без тегов, конвертируем их
    if grep -q "BEGIN CERTIFICATE" "$config_file" && grep -q "END CERTIFICATE" "$config_file"; then
        # Создаем директорию для сертификатов
        local cert_dir="${config_file%.ovpn}_certs"
        mkdir -p "$cert_dir"
        
        # Используем awk для извлечения PEM блоков
        awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$config_file" > "$cert_dir/ca.crt"
        awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$config_file" > "$cert_dir/client.key"
        awk '/BEGIN RSA PRIVATE KEY/,/END RSA PRIVATE KEY/' "$config_file" > "$cert_dir/client.key" 2>/dev/null
        
        # Если есть client certificate
        if grep -q "BEGIN CERTIFICATE" "$config_file" | grep -v "CA" | head -2; then
            # Более сложное извлечение клиентского сертификата
            sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$config_file" | tail -n +2 | head -n -1 > "$cert_dir/client.crt" 2>/dev/null
        fi
        
        # Создаем упрощенную конфигурацию
        local temp_file="${config_file}.new"
        
        # Сохраняем основные настройки
        grep -E "^(remote|proto|dev|resolv-retry|nobind|persist)" "$config_file" > "$temp_file"
        
        # Добавляем ссылки на файлы сертификатов
        echo "" >> "$temp_file"
        echo "ca $cert_dir/ca.crt" >> "$temp_file"
        echo "cert $cert_dir/client.crt" >> "$temp_file"
        echo "key $cert_dir/client.key" >> "$temp_file"
        echo "auth-user-pass auth.txt" >> "$temp_file"
        echo "remote-cert-tls server" >> "$temp_file"
        
        # Добавляем стандартные параметры
        echo "cipher AES-256-CBC" >> "$temp_file"
        echo "auth SHA256" >> "$temp_file"
        echo "verb 3" >> "$temp_file"
        
        mv "$temp_file" "$config_file"
    fi
    
    return 0
}

# Функция для создания простой, но работающей конфигурации
create_simple_config() {
    local raw_config="$1"
    local output_config="$2"
    local ip="$3"
    
    # Извлекаем основные данные
    local remote_line=$(grep "^remote" "$raw_config" | head -1)
    local remote_server=$(echo "$remote_line" | awk '{print $2}')
    local remote_port=$(echo "$remote_line" | awk '{print $3}')
    remote_port=${remote_port:-1194}
    
    # Создаем директорию для сертификатов
    local cert_dir="${output_config%.ovpn}_certs"
    mkdir -p "$cert_dir"
    
    # Пытаемся извлечь сертификаты разными способами
    if grep -q "<cert>" "$raw_config"; then
        # Из тегов
        sed -n '/<cert>/,/<\/cert>/p' "$raw_config" | sed '1d;$d' | sed '/^$/d' > "$cert_dir/client.crt"
        sed -n '/<key>/,/<\/key>/p' "$raw_config" | sed '1d;$d' | sed '/^$/d' > "$cert_dir/client.key"
        sed -n '/<ca>/,/<\/ca>/p' "$raw_config" | sed '1d;$d' | sed '/^$/d' > "$cert_dir/ca.crt"
    else
        # Из PEM блоков
        awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "$raw_config" | tail -n +2 | head -n -1 > "$cert_dir/ca.crt" 2>/dev/null
        awk '/-----BEGIN PRIVATE KEY-----/,/-----END PRIVATE KEY-----/' "$raw_config" | tail -n +2 | head -n -1 > "$cert_dir/client.key" 2>/dev/null
        awk '/-----BEGIN RSA PRIVATE KEY-----/,/-----END RSA PRIVATE KEY-----/' "$raw_config" | tail -n +2 | head -n -1 > "$cert_dir/client.key" 2>/dev/null
    fi
    
    # Проверяем, что файлы не пустые
    for cert_file in "$cert_dir/client.crt" "$cert_dir/client.key" "$cert_dir/ca.crt"; do
        if [ ! -s "$cert_file" ]; then
            # Пробуем другой метод извлечения
            if [ "$cert_file" = "$cert_dir/ca.crt" ]; then
                grep -A 100 "BEGIN CERTIFICATE" "$raw_config" | grep -B 100 "END CERTIFICATE" | sed '/^--$/d' > "$cert_file" 2>/dev/null
            fi
        fi
    done
    
    # Создаем простую конфигурацию
    cat > "$output_config" << EOF
client
dev tun
proto udp
remote $remote_server $remote_port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
verb 2
mute 20

ca $cert_dir/ca.crt
cert $cert_dir/client.crt
key $cert_dir/client.key
auth-user-pass auth.txt
EOF
    
    # Проверяем, есть ли tls-auth
    if grep -q "<tls-auth>" "$raw_config"; then
        sed -n '/<tls-auth>/,/<\/tls-auth>/p' "$raw_config" | sed '1d;$d' | sed '/^$/d' > "$cert_dir/ta.key"
        echo "tls-auth $cert_dir/ta.key 1" >> "$output_config"
    fi
    
    # Удаляем пустые строки
    sed -i '/^$/d' "$output_config"
    
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

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR" || exit 1

# Функция для загрузки CSV
download_csv() {
    local url=$1
    local output=$2
    
    log "Загрузка с $url"
    
    curl -s --connect-timeout 30 --max-time 60 \
         -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
         "$url" -o "$output"
    
    if [ -f "$output" ] && [ -s "$output" ] && ! grep -q "<html\|<!DOCTYPE" "$output" 2>/dev/null; then
        log "✓ CSV загружен ($(wc -l < "$output") строк)"
        return 0
    fi
    
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
    exit 1
fi

# Пропускаем заголовок
tail -n +3 servers.csv > data.csv 2>/dev/null
if [ ! -s data.csv ]; then
    cp servers.csv data.csv
fi

# Создаем auth.txt
echo -e "${AUTH_LOGIN}\n${AUTH_PASS}" > auth.txt

# Парсим CSV
log "Парсинг CSV и создание .ovpn файлов..."
LINE_NUM=0
OVPN_COUNT=0

while IFS= read -r line || [ -n "$line" ]; do
    ((LINE_NUM++))
    
    line=$(echo "$line" | tr -d '\r')
    [ -z "$line" ] && continue
    
    # Извлекаем IP
    IP=$(echo "$line" | awk -F',' '{print $2}' | sed 's/"//g')
    
    # Ищем поле с base64 (последнее поле)
    FIELD_COUNT=$(echo "$line" | awk -F',' '{print NF}')
    BASE64_FIELD=$(echo "$line" | awk -F',' -v f="$FIELD_COUNT" '{print $f}' | sed 's/"//g')
    
    if [ -z "$BASE64_FIELD" ] || [ "$BASE64_FIELD" = "0" ]; then
        continue
    fi
    
    # Декодируем
    DECODED=$(echo "$BASE64_FIELD" | base64 -d 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$DECODED" ]; then
        continue
    fi
    
    # Проверяем, что это OpenVPN конфигурация
    if echo "$DECODED" | grep -q -i "openvpn\|client\|remote\|BEGIN CERTIFICATE"; then
        # Сохраняем сырые данные
        RAW_FILE="raw_${IP:-server_$LINE_NUM}.ovpn"
        echo "$DECODED" > "$RAW_FILE"
        
        # Создаем рабочую конфигурацию
        CONFIG_FILE="vpngate_${IP:-server_$LINE_NUM}.ovpn"
        
        create_simple_config "$RAW_FILE" "$CONFIG_FILE" "$IP"
        
        if [ -s "$CONFIG_FILE" ]; then
            ((OVPN_COUNT++))
            echo "✓ Создан: $CONFIG_FILE"
        else
            rm -f "$CONFIG_FILE" 2>/dev/null
        fi
        
        rm -f "$RAW_FILE" 2>/dev/null
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

# Функция тестирования конфигурации
test_ovpn_config() {
    local config="$1"
    local config_name=$(basename "$config")
    local pid_file="/tmp/${config_name}.pid"
    local log_file="/tmp/${config_name}.log"
    
    echo -n "Тест $config_name ... "
    
    # Проверяем основные параметры
    if ! grep -q "^remote " "$config"; then
        echo "❌ нет remote"
        return 1
    fi
    
    if ! grep -q "^ca " "$config" || ! grep -q "^cert " "$config" || ! grep -q "^key " "$config"; then
        echo "❌ нет сертификатов"
        return 1
    fi
    
    # Запускаем OpenVPN
    sudo openvpn \
        --config "$config" \
        --daemon \
        --writepid "$pid_file" \
        --log "$log_file" \
        --verb 1 \
        --connect-timeout 20 \
        --auth-user-pass auth.txt
    
    # Ждем подключения
    for i in {1..20}; do
        if [ -f "$log_file" ] && grep -q "Initialization Sequence Completed" "$log_file" 2>/dev/null; then
            sleep 2
            NEW_IP=$(timeout 5 curl -s --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '\n\r')
            
            if [ -n "$NEW_IP" ] && [ "$NEW_IP" != "$ORIGINAL_IP" ]; then
                echo "✅ РАБОТАЕТ (IP: $NEW_IP)"
                
                # Сохраняем рабочую конфигурацию
                cp "$config" "$OUTPUT_DIR/"
                # Копируем директорию с сертификатами
                cert_dir="${config%.ovpn}_certs"
                if [ -d "$cert_dir" ]; then
                    cp -r "$cert_dir" "$OUTPUT_DIR/"
                fi
                
                # Останавливаем OpenVPN
                if [ -f "$pid_file" ]; then
                    sudo kill $(cat "$pid_file") 2>/dev/null
                    sleep 1
                fi
                
                return 0
            else
                echo "⚠️  подключено, IP: $NEW_IP"
                break
            fi
        fi
        
        # Проверяем ошибки
        if [ -f "$log_file" ]; then
            if grep -q "AUTH_FAILED\|TLS Error\|Cannot load\|no start line" "$log_file"; then
                ERROR=$(grep -i "error\|fail\|cannot" "$log_file" | tail -1)
                echo "❌ ${ERROR:0:50}"
                break
            fi
        fi
        
        sleep 1
    done
    
    # Останавливаем OpenVPN
    if [ -f "$pid_file" ]; then
        sudo kill $(cat "$pid_file") 2>/dev/null
        sleep 1
    fi
    
    return 1
}

# Тестируем конфигурации
log "Тестируем конфигурации..."
WORKING=0
TESTED=0

for f in vpngate_*.ovpn; do
    if [ -f "$f" ]; then
        ((TESTED++))
        
        if test_ovpn_config "$f"; then
            ((WORKING++))
            if [ "$WORKING" -ge 3 ]; then
                log "Найдено 3 рабочих конфигурации"
                break
            fi
        fi
        
        if [ "$TESTED" -ge 15 ]; then
            log "Протестировано 15 конфигураций"
            break
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
    echo "Конфигурации сохранены в: $OUTPUT_DIR"
    echo ""
    echo "Для подключения:"
    echo "1. cd \"$OUTPUT_DIR\""
    echo "2. sudo openvpn --config ИМЯ_ФАЙЛА.ovpn"
else
    echo "❌ Не найдено рабочих конфигураций"
    echo ""
    echo "ПОПРОБУЙТЕ ЭТО:"
    echo "1. Проверить файлы сертификатов вручную:"
    echo "   ls *_certs/"
    echo "2. Проверить один конфиг вручную:"
    echo "   sudo openvpn --config vpngate_XXX.ovpn"
    echo "3. VPN Gate может быть временно недоступен"
fi

echo "========================================"

# Очистка
rm -rf "$WORK_DIR"
log "Готово!"
