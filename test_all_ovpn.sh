#!/bin/bash

# --- Настройки ---
WORK_DIR="/tmp/vpngate_test_$$"
OUTPUT_DIR="$HOME/Загрузки/vpngate_working"
VPNGATE_URL="https://download.vpngate.jp/api/iphone/"
AUTH_LOGIN="vpn"
AUTH_PASS="vpn"

# --- Проверка зависимостей ---
for cmd in curl openvpn ip base64; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ Требуется: $cmd. Установите: sudo apt install $(echo $cmd | sed 's/ip/iproute2/')"
        exit 1
    fi
done

# --- Подготовка ---
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
cd "$WORK_DIR" || { echo "Не удалось войти в $WORK_DIR"; exit 1; }

echo "📥 Загрузка CSV с download.vpngate.jp..."
curl -s "$VPNGATE_URL" -o servers.csv

# Пропускаем первую строку (заголовки)
tail -n +2 servers.csv | grep -v "^#" > data.csv

if [ ! -s data.csv ]; then
    echo "❌ CSV пуст или недоступен."
    head -n 3 servers.csv
    exit 1
fi

TOTAL=$(wc -l < data.csv)
echo "Найдено $TOTAL серверов. Декодирование .ovpn..."

# Извлекаем base64 из последнего поля и декодируем
awk -F',' '{
    if (NF >= 15) {
        # Убираем возможные кавычки и экранирование
        gsub(/^"|"$/, "", $15);
        gsub(/\\"/, "\"", $15);
        print $15
    }
}' data.csv | while read -r b64; do
    if [[ -n "$b64" && "$b64" != "0" ]]; then
        # Получаем IP из предыдущего поля (поле 2)
        IP=$(awk -F',' -v line="$b64" 'BEGIN{FS=","} {if($15==line) print $2}' ../data.csv 2>/dev/null)
        [[ -z "$IP" ]] && IP="unknown"

        FILENAME="vpngate_${IP}.ovpn"
        echo "$b64" | base64 -d > "$FILENAME" 2>/dev/null

        # Добавляем auth-user-pass, если не указано
        if ! grep -q "auth-user-pass" "$FILENAME" 2>/dev/null; then
            echo "auth-user-pass auth.txt" >> "$FILENAME"
        fi
    fi
done

# Создаём auth.txt
echo -e "${AUTH_LOGIN}\n${AUTH_PASS}" > auth.txt

# Считаем, сколько .ovpn получилось
OVPN_COUNT=$(find . -maxdepth 1 -name "*.ovpn" | wc -l)
if [ "$OVPN_COUNT" -eq 0 ]; then
    echo "❌ Не удалось создать ни одного .ovpn файла."
    exit 1
fi

echo "Создано $OVPN_COUNT .ovpn файлов. Проверка..."

# --- Функция проверки через смену IP ---
ORIGINAL_IP=$(timeout 8 curl -s --max-time 6 https://httpbin.org/ip 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null)
echo "Текущий IP: ${ORIGINAL_IP:-неизвестен}"

test_ovpn() {
    local config="$1"
    local PID_FILE="/tmp/vpngate_pid_$$"
    local LOG_FILE="/tmp/vpngate_log_$$"
    local TUN_IFACE=""

    sudo openvpn --config "$config" --daemon --writepid "$PID_FILE" --log "$LOG_FILE" --auth-nocache --connect-timeout 20 --verb 1 >/dev/null 2>&1

    for i in {1..25}; do
        TUN_IFACE=$(ip a show 2>/dev/null | grep -o 'tun[0-9]' | head -n1)
        if [ -n "$TUN_IFACE" ]; then break; fi
        sleep 1
    done

    if [ -z "$TUN_IFACE" ]; then
        sudo kill $(cat "$PID_FILE" 2>/dev/null) 2>/dev/null
        return 1
    fi

    sleep 4
    NEW_IP=$(timeout 10 curl -s --max-time 8 https://httpbin.org/ip 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null)

    sudo kill $(cat "$PID_FILE" 2>/dev/null) 2>/dev/null
    sleep 2
    sudo ip link delete "$TUN_IFACE" 2>/dev/null
    rm -f "$PID_FILE" "$LOG_FILE"

    if [ -n "$NEW_IP" ] && ( [ -z "$ORIGINAL_IP" ] || [ "$NEW_IP" != "$ORIGINAL_IP" ] ); then
        return 0
    fi
    return 1
}

# --- Проверка всех ---
WORKING=0
for f in *.ovpn; do
    if [ -f "$f" ]; then
        echo -n "Проверка: $f ... "
        if test_ovpn "$f"; then
            cp "$f" "$OUTPUT_DIR/"
            echo "✅"
            ((WORKING++))
        else
            echo "❌"
        fi
    fi
done

cp auth.txt "$OUTPUT_DIR/" 2>/dev/null

echo
echo "✅ Готово! Рабочих серверов: $WORKING"
echo "Файлы сохранены в: $OUTPUT_DIR"

# Уборка
cd /tmp
rm -rf "$WORK_DIR"
