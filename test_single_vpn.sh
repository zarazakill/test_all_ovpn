#!/bin/bash

# Script to test a single VPN configuration file
# Usage: sudo ./test_single_vpn.sh <config.ovpn>

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "Usage: sudo $0 <config.ovpn>"
    exit 1
fi

CONFIG_FILE="$1"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: File $CONFIG_FILE not found"
    exit 1
fi

echo "Testing VPN configuration: $CONFIG_FILE"
echo "Press Ctrl+C to stop the connection after testing"

# Create a temporary directory for certificates if they're inline
CONFIG_DIR=$(dirname "$CONFIG_FILE")
CONFIG_NAME=$(basename "$CONFIG_FILE" .ovpn)
CERT_DIR="$CONFIG_DIR/${CONFIG_NAME}_certs"
mkdir -p "$CERT_DIR"

# Check if the config has inline certificates (between tags)
if grep -q "<ca>" "$CONFIG_FILE" && grep -q "</ca>" "$CONFIG_FILE"; then
    echo "Found inline CA certificate, extracting to $CERT_DIR..."
    sed -n '/<ca>/,/<\/ca>/p' "$CONFIG_FILE" | sed '1d;$d' > "$CERT_DIR/ca.crt"
    sed -i "s|ca .*|ca $CERT_DIR/ca.crt|" "$CONFIG_FILE"
fi

if grep -q "<cert>" "$CONFIG_FILE" && grep -q "</cert>" "$CONFIG_FILE"; then
    echo "Found inline client certificate, extracting to $CERT_DIR..."
    sed -n '/<cert>/,/<\/cert>/p' "$CONFIG_FILE" | sed '1d;$d' > "$CERT_DIR/client.crt"
    sed -i "s|cert .*|cert $CERT_DIR/client.crt|" "$CONFIG_FILE"
fi

if grep -q "<key>" "$CONFIG_FILE" && grep -q "</key>" "$CONFIG_FILE"; then
    echo "Found inline client key, extracting to $CERT_DIR..."
    sed -n '/<key>/,/<\/key>/p' "$CONFIG_FILE" | sed '1d;$d' > "$CERT_DIR/client.key"
    sed -i "s|key .*|key $CERT_DIR/client.key|" "$CONFIG_FILE"
fi

if grep -q "<tls-auth>" "$CONFIG_FILE" && grep -q "</tls-auth>" "$CONFIG_FILE"; then
    echo "Found inline tls-auth key, extracting to $CERT_DIR..."
    sed -n '/<tls-auth>/,/<\/tls-auth>/p' "$CONFIG_FILE" | sed '1d;$d' > "$CERT_DIR/ta.key"
    sed -i "s|tls-auth .*|tls-auth $CERT_DIR/ta.key 1|" "$CONFIG_FILE"
fi

# Create auth file if needed
if ! grep -q "auth-user-pass" "$CONFIG_FILE"; then
    echo "auth-user-pass auth.txt" >> "$CONFIG_FILE"
fi

if [ ! -f "auth.txt" ]; then
    echo "vpn" > auth.txt
    echo "vpn" >> auth.txt
fi

# Get original IP
echo "Getting original IP..."
ORIGINAL_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "unknown")
echo "Original IP: $ORIGINAL_IP"

# Start VPN connection
echo "Starting VPN connection..."
echo "Logs will be saved to ${CONFIG_NAME}.log"
sudo openvpn --config "$CONFIG_FILE" --log "${CONFIG_NAME}.log" --status "${CONFIG_NAME}_status.log" 10

# After connection is stopped, check new IP
echo "VPN connection ended."
NEW_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "unknown")
echo "Final IP: $NEW_IP"

if [ "$NEW_IP" != "$ORIGINAL_IP" ]; then
    echo "✅ VPN connection was successful! IP changed from $ORIGINAL_IP to $NEW_IP"
else
    echo "❌ VPN connection may not have been successful. IP remained $NEW_IP"
fi

# Show last lines of log
echo "Last 10 lines of log file:"
tail -10 "${CONFIG_NAME}.log"