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

while IFS= read -r line; do
    ((LINE_NUM++))

    # Удаляем Windows-символы
    line=$(echo "$line" | tr -d '\r')
    [ -z "$line" ] && continue

    # Разбиваем по запятым, сохраняя кавычки
    IFS=',' read -ra FIELDS <<< "$line"

    # Нужно минимум 15 полей
    if [ ${#FIELDS[@]} -lt 15 ]; then
        continue
    fi

    # IP из второго поля
    IP="${FIELDS[1]}"

    # Base64 из последнего поля (поле 15, индекс 14)
    BASE64_FIELD="${FIELDS[14]}"

    # Убираем кавычки если есть
    BASE64_FIELD=$(echo "$BASE64_FIELD" | sed 's/^"//; s/"$//; s/\\"/"/g')

    # Дополнительная проверка base64
    if [[ ${#BASE64_FIELD} -gt 200 ]] && [[ "$BASE64_FIELD" != "0" ]] &&
       echo "$BASE64_FIELD" | base64 -d 2>/dev/null | grep -q "client"; then

        FILENAME="vpngate_${IP:-unknown_$LINE_NUM}.ovpn"

        # Декодируем base64
        echo "$BASE64_FIELD" | base64 -d > "$FILENAME" 2>/dev/null

        if [ -s "$FILENAME" ]; then
            # Добавляем auth-user-pass если нет
            if ! grep -q "auth-user-pass" "$FILENAME"; then
                echo "auth-user-pass auth.txt" >> "$FILENAME"
            fi

            # Проверяем, что файл содержит минимально необходимые настройки
            if grep -q "remote " "$FILENAME" && grep -q "client" "$FILENAME"; then
                ((OVPN_COUNT++))
                echo "✓ Создан: $FILENAME"
            else
                rm -f "$FILENAME"
            fi
        else
            rm -f "$FILENAME" 2>/dev/null
        fi
    fi
done < data.csv

echo "Создано $OVPN_COUNT .ovpn файлов."

if [ "$OVPN_COUNT" -eq 0 ]; then
    echo "❌ Не создано ни одного .ovpn файла."
    echo "Проверьте формат CSV. Возможно, изменилась структура."
    exit 1
fi

# Проверка текущего IP
echo "Текущий IP:"
ORIGINAL_IP=$(timeout 10 curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo "неизвестен")
echo "$ORIGINAL_IP"

# Улучшенная функция тестирования
test_ovpn() {
    local config="$1"
    local PID_FILE="/tmp/vpngate_pid_$$"
    local LOG_FILE="/tmp/vpngate_log_$$"
    local TUN_IFACE=""
    local TIMEOUT=20

    # Запуск OpenVPN
    sudo openvpn \
        --config "$config" \
        --daemon \
        --writepid "$PID_FILE" \
        --log "$LOG_FILE" \
        --auth-nocache \
        --connect-timeout 15 \
        --verb 0 \
        --proto udp

    # Ждем создания tun интерфейса
    for i in {1..30}; do
        TUN_IFACE=$(ip -o link show 2>/dev/null | grep -o 'tun[0-9]' | head -n1)
        if [ -n "$TUN_IFACE" ]; then
            break
        fi
        sleep 1
    done

    if [ -z "$TUN_IFACE" ]; then
        echo "  ⚠ Нет tun интерфейса" >&2
        sudo pkill -f "openvpn.*$config" 2>/dev/null
        return 1
    fi

    # Ждем установки маршрутов
    sleep 3

    # Проверяем IP через несколько сервисов
    local NEW_IP=""
    for service in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me/ip"; do
        NEW_IP=$(timeout 8 curl -s --max-time 5 "$service" 2>/dev/null)
        if [ -n "$NEW_IP" ]; then
            break
        fi
    done

    # Останавливаем OpenVPN
    sudo pkill -f "openvpn.*$config" 2>/dev/null
    sleep 2

    # Чистим интерфейс
    sudo ip link delete "$TUN_IFACE" 2>/dev/null
    rm -f "$PID_FILE" "$LOG_FILE"

    # Проверяем результат
    if [ -n "$NEW_IP" ] && [ "$NEW_IP" != "$ORIGINAL_IP" ]; then
        echo "  ✅ IP изменен: $NEW_IP" >&2
        return 0
    else
        echo "  ⚠ IP не изменился или ошибка" >&2
        return 1
    fi
}

# Тестируем только первые 10 для экономии времени
echo "Тестируем первые 10 конфигураций..."
WORKING=0
TESTED=0

for f in *.ovpn; do
    if [ -f "$f" ]; then
        ((TESTED++))
        echo -n "Тест $TESTED: $f ... "

        # Пропускаем если файл пустой
        if [ ! -s "$f" ]; then
            echo "пустой файл"
            continue
        fi

        if test_ovpn "$f"; then
            cp "$f" "$OUTPUT_DIR/"
            echo "✅ РАБОТАЕТ"
            ((WORKING++))

            # Если нашли 3 рабочих, можно остановиться
            if [ "$WORKING" -ge 3 ]; then
                echo "Найдено достаточно рабочих конфигураций"
                break
            fi
        else
            echo "❌"
        fi

        # Ограничиваем тестирование 10 файлами
        if [ "$TESTED" -ge 10 ]; then
            break
        fi
    fi
done

# Копируем auth.txt
cp auth.txt "$OUTPUT_DIR/" 2>/dev/null

echo ""
echo "========================================"
echo "Результаты:"
echo "  Протестировано: $TESTED"
echo "  Рабочих: $WORKING"
echo "  Сохранено в: $OUTPUT_DIR"
echo "========================================"

# Очистка
cd /tmp
rm -rf "$WORK_DIR"
