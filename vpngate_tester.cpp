// vpngate_tester.cpp
#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <cstdlib>
#include <ctime>
#include <cstring>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <sys/wait.h>
#include <curl/curl.h>
#include <openssl/evp.h>
#include <openssl/bio.h>
#include <openssl/buffer.h>
#include <iomanip>
#include <algorithm>
#include <regex>
#include <filesystem>

namespace fs = std::filesystem;

// Конфигурация
struct Config {
    std::string vpngate_url = "https://download.vpngate.jp/api/iphone/";
    std::string auth_login = "vpn";
    std::string auth_pass = "vpn";
    std::string output_dir = "/workspace/vpngate_working";
    int test_timeout = 30;
    int max_servers_to_test = 10;
    int max_working_servers = 3;
};

// Информация о сервере
struct ServerInfo {
    std::string hostname;
    std::string ip;
    std::string country;
    std::string country_short;
    int score;
    int ping;
    int speed_mbps;
    int sessions;
    std::string uptime;
    std::string config_base64;
    std::string config_filename;
    std::string proto;
    int port;
    bool tested;
    bool available;
    int test_ping;
};

// Callback для curl
size_t WriteCallback(void* contents, size_t size, size_t nmemb, std::string* output) {
    size_t total_size = size * nmemb;
    output->append((char*)contents, total_size);
    return total_size;
}

// Скачивание CSV
std::string download_csv(const std::string& url) {
    CURL* curl = curl_easy_init();
    if (!curl) {
        throw std::runtime_error("Не удалось инициализировать curl");
    }

    std::string response;

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);

    CURLcode res = curl_easy_perform(curl);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        throw std::runtime_error("Ошибка загрузки: " + std::string(curl_easy_strerror(res)));
    }

    return response;
}

// Base64 декодирование
std::string base64_decode(const std::string& encoded) {
    BIO* b64 = BIO_new(BIO_f_base64());
    BIO* mem = BIO_new_mem_buf(encoded.c_str(), encoded.length());
    BIO_push(b64, mem);
    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);

    std::vector<char> buffer(encoded.length());
    int length = BIO_read(b64, buffer.data(), buffer.size());

    BIO_free_all(b64);

    if (length > 0) {
        return std::string(buffer.data(), length);
    }
    return "";
}

// Проверка доступности порта
bool check_port(const std::string& host, int port, int timeout_sec = 3) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        return false;
    }

    struct sockaddr_in server_addr;
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);

    // Преобразуем hostname в IP
    struct hostent* he = gethostbyname(host.c_str());
    if (!he) {
        close(sock);
        return false;
    }

    memcpy(&server_addr.sin_addr, he->h_addr_list[0], he->h_length);

    // Устанавливаем таймаут
    struct timeval timeout;
    timeout.tv_sec = timeout_sec;
    timeout.tv_usec = 0;

    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    // Пробуем подключиться
    bool result = (connect(sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) == 0);
    close(sock);

    return result;
}

// Получение текущего IP
std::string get_current_ip() {
    CURL* curl = curl_easy_init();
    if (!curl) {
        return "unknown";
    }

    std::string response;

    curl_easy_setopt(curl, CURLOPT_URL, "https://api.ipify.org");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 5L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);

    CURLcode res = curl_easy_perform(curl);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        // Пробуем резервный сервис
        curl = curl_easy_init();
        curl_easy_setopt(curl, CURLOPT_URL, "https://icanhazip.com");
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 5L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);

        res = curl_easy_perform(curl);
        curl_easy_cleanup(curl);
    }

    // Убираем переводы строк
    response.erase(std::remove(response.begin(), response.end(), '\n'), response.end());
    response.erase(std::remove(response.begin(), response.end(), '\r'), response.end());

    return response.empty() ? "unknown" : response;
}

// Парсинг CSV строки
ServerInfo parse_csv_line(const std::string& line, int line_num) {
    ServerInfo server;
    server.tested = false;
    server.available = false;
    server.test_ping = 999;
    server.port = 1194;
    server.proto = "udp";

    std::stringstream ss(line);
    std::string field;
    std::vector<std::string> fields;

    // Простой парсинг CSV (без учета кавычек для простоты)
    while (std::getline(ss, field, ',')) {
        // Убираем кавычки
        if (!field.empty() && field.front() == '"' && field.back() == '"') {
            field = field.substr(1, field.size() - 2);
        }
        fields.push_back(field);
    }

    if (fields.size() < 15) {
        throw std::runtime_error("Недостаточно полей в строке " + std::to_string(line_num));
    }

    server.hostname = fields[0];
    server.ip = fields[1];
    server.score = std::stoi(fields[2]);
    server.ping = std::stoi(fields[3]);
    server.speed_mbps = std::stoi(fields[4]) / 1000000;
    server.country_short = fields[5];
    server.country = fields[6];
    server.sessions = std::stoi(fields[7]);
    server.uptime = fields[8];
    server.config_base64 = fields[14];

    // Создаем имя файла
    std::string safe_hostname = server.hostname;
    std::replace_if(safe_hostname.begin(), safe_hostname.end(),
                   [](char c) { return !std::isalnum(c) && c != '.' && c != '-'; }, '_');

    std::string safe_country = server.country_short;
    std::replace_if(safe_country.begin(), safe_country.end(),
                   [](char c) { return !std::isalnum(c); }, '_');

    server.config_filename = "vpngate_" + server.ip + "_" + safe_country + ".ovpn";

    return server;
}

// Создание конфигурационного файла
bool create_config_file(const ServerInfo& server, const Config& config, const std::string& work_dir) {
    std::string config_content = base64_decode(server.config_base64);
    if (config_content.empty()) {
        return false;
    }

    // Проверяем, что это OpenVPN конфиг
    if (config_content.find("client") == std::string::npos &&
        config_content.find("remote ") == std::string::npos) {
        return false;
    }

    std::string filepath = work_dir + "/" + server.config_filename;
    std::ofstream file(filepath);
    if (!file.is_open()) {
        return false;
    }

    // Записываем исходный конфиг
    file << config_content;

    // Добавляем auth-user-pass если нет
    if (config_content.find("auth-user-pass") == std::string::npos) {
        file << "\n# VPN Gate credentials: " << config.auth_login << "/" << config.auth_pass;
        file << "\nauth-user-pass auth.txt\n";
    }

    // Добавляем стандартные параметры
    std::vector<std::string> standard_params = {
        "persist-key",
        "persist-tun",
        "nobind",
        "remote-cert-tls server",
        "verb 3"
    };

    for (const auto& param : standard_params) {
        if (config_content.find(param) == std::string::npos) {
            file << param << "\n";
        }
    }

    file.close();

    // Создаем auth.txt если нужно
    std::string auth_file = work_dir + "/auth.txt";
    if (!fs::exists(auth_file)) {
        std::ofstream auth(auth_file);
        if (auth.is_open()) {
            auth << config.auth_login << "\n" << config.auth_pass << "\n";
            auth.close();
        }
    }

    return true;
}

// Тестирование OpenVPN подключения
bool test_openvpn_connection(const ServerInfo& server, const Config& config,
                            const std::string& work_dir, const std::string& original_ip) {
    std::string config_path = work_dir + "/" + server.config_filename;
    std::string log_path = work_dir + "/" + server.config_filename + ".log";
    std::string pid_path = work_dir + "/" + server.config_filename + ".pid";

    // Запускаем OpenVPN
    std::string cmd = "sudo timeout " + std::to_string(config.test_timeout) +
                     " openvpn --config \"" + config_path +
                     "\" --verb 3 --connect-timeout 20 --log \"" + log_path +
                     "\" --writepid \"" + pid_path + "\"";

    int result = system(cmd.c_str());

    // Проверяем лог
    std::ifstream log_file(log_path);
    if (log_file.is_open()) {
        std::string log_content((std::istreambuf_iterator<char>(log_file)),
                               std::istreambuf_iterator<char>());
        log_file.close();

        if (log_content.find("Initialization Sequence Completed") != std::string::npos) {
            // Проверяем IP
            std::string new_ip = get_current_ip();
            if (new_ip != "unknown" && new_ip != original_ip) {
                std::cout << "  ✅ РАБОТАЕТ (IP: " << new_ip << ")" << std::endl;
                return true;
            } else {
                std::cout << "  ⚠️  Подключено, но IP не изменился" << std::endl;
            }
        } else if (log_content.find("AUTH_FAILED") != std::string::npos) {
            std::cout << "  ❌ Ошибка аутентификации" << std::endl;
        } else if (log_content.find("TLS Error") != std::string::npos) {
            std::cout << "  ❌ Ошибка TLS" << std::endl;
        } else if (log_content.find("Cannot load") != std::string::npos ||
                  log_content.find("no start line") != std::string::npos) {
            std::cout << "  ❌ Проблема с сертификатами" << std::endl;
        } else if (log_content.find("Connection refused") != std::string::npos) {
            std::cout << "  ❌ Соединение отклонено" << std::endl;
        } else {
            std::cout << "  ❌ Неизвестная ошибка" << std::endl;
        }
    }

    return false;
}

// Основная функция
int main(int argc, char* argv[]) {
    std::cout << "=== VPN GATE TESTER (C++) ===" << std::endl;

    Config config;

    // Инициализация curl
    curl_global_init(CURL_GLOBAL_DEFAULT);

    try {
        // Создаем рабочую директорию
        std::string work_dir = "/tmp/vpngate_test_" + std::to_string(time(nullptr));
        fs::create_directories(work_dir);
        fs::create_directories(config.output_dir);

        // Скачиваем CSV
        std::cout << "[1/5] Скачиваем список серверов..." << std::endl;
        std::string csv_data = download_csv(config.vpngate_url);

        // Парсим CSV
        std::cout << "[2/5] Парсим CSV..." << std::endl;
        std::vector<ServerInfo> servers;

        std::stringstream ss(csv_data);
        std::string line;
        int line_num = 0;

        while (std::getline(ss, line)) {
            line_num++;

            // Пропускаем заголовки и комментарии
            if (line_num <= 2 || line.empty() || line[0] == '#' || line[0] == '*') {
                continue;
            }

            try {
                ServerInfo server = parse_csv_line(line, line_num);
                if (!server.config_base64.empty() && server.config_base64 != "0") {
                    servers.push_back(server);
                }
            } catch (const std::exception& e) {
                // Пропускаем некорректные строки
            }
        }

        std::cout << "Найдено серверов: " << servers.size() << std::endl;

        if (servers.empty()) {
            std::cout << "❌ Нет серверов для тестирования" << std::endl;
            return 1;
        }

        // Создаем конфигурационные файлы
        std::cout << "[3/5] Создаем конфигурации..." << std::endl;
        std::vector<ServerInfo> valid_servers;

        for (auto& server : servers) {
            if (create_config_file(server, config, work_dir)) {
                valid_servers.push_back(server);
                std::cout << "✓ " << server.config_filename << std::endl;
            }

            if (valid_servers.size() >= 20) { // Ограничиваем количество
                break;
            }
        }

        std::cout << "Создано конфигураций: " << valid_servers.size() << std::endl;

        // Получаем текущий IP
        std::cout << "[4/5] Проверяем текущий IP..." << std::endl;
        std::string original_ip = get_current_ip();
        std::cout << "Текущий IP: " << original_ip << std::endl;

        // Тестируем серверы
        std::cout << "[5/5] Тестируем серверы..." << std::endl;
        int tested = 0;
        int working = 0;

        for (auto& server : valid_servers) {
            tested++;

            std::cout << "\n--- Тест " << tested << ": " << server.config_filename << " ---" << std::endl;
            std::cout << "  IP: " << server.ip << ", Страна: " << server.country << std::endl;

            // Проверяем порт
            if (check_port(server.ip, server.port)) {
                std::cout << "  ✅ Порт доступен" << std::endl;
            } else {
                std::cout << "  ⚠️  Порт недоступен (может быть нормально для UDP)" << std::endl;
            }

            // Тестируем OpenVPN
            if (test_openvpn_connection(server, config, work_dir, original_ip)) {
                server.available = true;
                working++;

                // Копируем рабочую конфигурацию
                std::string src_path = work_dir + "/" + server.config_filename;
                std::string dst_path = config.output_dir + "/" + server.config_filename;
                fs::copy_file(src_path, dst_path, fs::copy_options::overwrite_existing);

                // Копируем auth.txt
                std::string auth_src = work_dir + "/auth.txt";
                std::string auth_dst = config.output_dir + "/auth.txt";
                if (fs::exists(auth_src)) {
                    fs::copy_file(auth_src, auth_dst, fs::copy_options::overwrite_existing);
                }

                if (working >= config.max_working_servers) {
                    std::cout << "\nНайдено достаточно рабочих серверов" << std::endl;
                    break;
                }
            }

            if (tested >= config.max_servers_to_test) {
                std::cout << "\nПротестировано достаточно серверов" << std::endl;
                break;
            }
        }

        // Итоговый отчет
        std::cout << "\n========================================" << std::endl;
        std::cout << "ИТОГОВЫЙ ОТЧЕТ" << std::endl;
        std::cout << "========================================" << std::endl;
        std::cout << "Всего серверов: " << servers.size() << std::endl;
        std::cout << "Конфигураций создано: " << valid_servers.size() << std::endl;
        std::cout << "Протестировано: " << tested << std::endl;
        std::cout << "Рабочих: " << working << std::endl;
        std::cout << "Выходная директория: " << config.output_dir << std::endl;
        std::cout << "========================================" << std::endl;

        if (working > 0) {
            std::cout << "\n✅ УСПЕХ! Рабочие конфигурации:" << std::endl;
            for (const auto& entry : fs::directory_iterator(config.output_dir)) {
                if (entry.path().extension() == ".ovpn") {
                    std::cout << "  - " << entry.path().filename().string() << std::endl;
                }
            }

            std::cout << "\nДля подключения:" << std::endl;
            std::cout << "cd \"" << config.output_dir << "\"" << std::endl;
            std::cout << "sudo openvpn --config <файл.ovpn>" << std::endl;
        } else {
            std::cout << "\n❌ Рабочих конфигураций не найдено" << std::endl;
            std::cout << "\nРекомендации:" << std::endl;
            std::cout << "1. Попробуйте запустить позже" << std::endl;
            std::cout << "2. VPN Gate может быть временно недоступен" << std::endl;
            std::cout << "3. Проверьте логи в: " << work_dir << std::endl;
        }

        // Очистка рабочей директории
        fs::remove_all(work_dir);

    } catch (const std::exception& e) {
        std::cerr << "❌ Ошибка: " << e.what() << std::endl;
        curl_global_cleanup();
        return 1;
    }

    curl_global_cleanup();
    return 0;
}
