#include <iostream>
#include <curl/curl.h>
#include <string>
#include <vector>

size_t WriteCallback(void* contents, size_t size, size_t nmemb, std::string* response) {
    size_t total_size = size * nmemb;
    response->append((char*)contents, total_size);
    return total_size;
}

int main() {
    CURL* curl = curl_easy_init();
    if (!curl) {
        std::cout << "Failed to initialize curl" << std::endl;
        return 1;
    }

    std::string response;

    // Try multiple potential URLs
    std::vector<std::string> urls = {
        "https://download.vpngate.jp/api/iphone/",
        "https://www.vpngate.net/api/iphone/",
        "http://www.vpngate.net/api/iphone/"
    };

    for (const auto& url : urls) {
        std::cout << "\nTrying URL: " << url << std::endl;
        
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_USERAGENT, "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36");
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 15L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
        
        response.clear(); // Clear previous response
        CURLcode res = curl_easy_perform(curl);
        
        if (res != CURLE_OK) {
            std::cout << "Error: " << curl_easy_strerror(res) << std::endl;
            continue;
        }
        
        long response_code;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
        std::cout << "Response code: " << response_code << std::endl;
        
        // Check if response looks like CSV (starts with hostname)
        if (response.length() > 10) {
            std::string preview = response.substr(0, 50);
            std::cout << "Response preview: " << preview << (response.length() > 50 ? "..." : "") << std::endl;
            
            // Check if it starts with CSV header (typically starts with hostname)
            if (preview.find("hostname") != std::string::npos || preview.find(",") != std::string::npos) {
                std::cout << "✓ Potential CSV data found!" << std::endl;
                break;
            } else {
                std::cout << "✗ HTML response (not CSV data)" << std::endl;
            }
        }
    }

    curl_easy_cleanup(curl);
    return 0;
}