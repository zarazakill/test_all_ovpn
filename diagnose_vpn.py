#!/usr/bin/env python3
import subprocess
import time
import os
import sys
import socket
import requests

def diagnose_vpn(config_file):
    print(f"\n🔍 Диагностика конфигурации: {config_file}")
    
    # 1. Проверяем содержимое конфигурации
    with open(config_file, 'r') as f:
        content = f.read()
    
    required_directives = ['remote', 'client', 'ca', 'cert', 'key']
    missing = []
    for directive in required_directives:
        if directive not in content:
            missing.append(directive)
    
    if missing:
        print(f"  ❌ Отсутствуют обязательные директивы: {', '.join(missing)}")
    
    # Извлекаем адрес сервера
    remote_lines = [l for l in content.split('\n') if l.startswith('remote ')]
    if remote_lines:
        server = remote_lines[0].split()[1]
        port = remote_lines[0].split()[2] if len(remote_lines[0].split()) > 2 else '1194'
        print(f"  ℹ️  Сервер: {server}:{port}")
        
        # Проверяем доступность порта
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            result = sock.connect_ex((server, int(port)))
            if result == 0:
                print(f"  ✅ Порт {port} доступен")
            else:
                print(f"  ❌ Порт {port} недоступен")
            sock.close()
        except Exception as e:
            print(f"  ⚠️  Не удалось проверить порт: {e}")
    
    # 2. Запускаем OpenVPN в режиме тестирования
    print("  🚀 Запуск OpenVPN для тестирования...")
    
    # Убиваем старые процессы
    subprocess.run(['sudo', 'pkill', '-f', f'openvpn.*{os.path.basename(config_file)}'], 
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    # Запускаем OpenVPN
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_file = os.path.join(script_dir, "logs", f"openvpn_test_{int(time.time())}.log")
    os.makedirs(os.path.dirname(log_file), exist_ok=True)
    process = subprocess.Popen([
        'sudo', 'openvpn',
        '--config', config_file,
        '--verb', '3',
        '--connect-timeout', '20',
        '--log', log_file
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    
    # Ждем 15 секунд
    time.sleep(15)
    
    # Проверяем логи
    if os.path.exists(log_file):
        with open(log_file, 'r') as f:
            logs = f.read()
        
        if 'Initialization Sequence Completed' in logs:
            print("  ✅ Успешное подключение")
            
            # Проверяем IP
            try:
                new_ip = requests.get('https://api.ipify.org', timeout=5).text
                print(f"  🌐 Новый IP: {new_ip}")
            except:
                print("  ⚠️  Не удалось проверить новый IP")
            
            result = True
        elif 'AUTH_FAILED' in logs:
            print("  ❌ Ошибка аутентификации")
            result = False
        elif 'TLS Error' in logs:
            print("  ❌ Ошибка TLS")
            result = False
        elif 'Connection refused' in logs or 'No route to host' in logs:
            print("  ❌ Сервер недоступен")
            result = False
        else:
            print("  ⚠️  Неизвестная ошибка (проверьте логи)")
            # Показываем последние строки лога
            last_lines = '\n'.join(logs.strip().split('\n')[-5:])
            print(f"  📋 Последние строки лога:\n{last_lines}")
            result = False
    else:
        print("  ❌ Лог-файл не создан")
        result = False
    
    # Останавливаем процесс
    process.terminate()
    subprocess.run(['sudo', 'pkill', '-f', f'openvpn.*{os.path.basename(config_file)}'])
    
    return result

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Использование: python3 diagnose.py <config.ovpn>")
        sys.exit(1)
    
    success = diagnose_vpn(sys.argv[1])
    sys.exit(0 if success else 1)