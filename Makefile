# Makefile
CXX = g++
CXXFLAGS = -std=c++17 -Wall -Wextra -O2
LDFLAGS = -lcurl -lssl -lcrypto -lpthread

# Для Ubuntu/Debian установите зависимости:
# sudo apt install libcurl4-openssl-dev libssl-dev

TARGET = vpngate_tester
SRC = vpngate_tester.cpp

all: $(TARGET)

$(TARGET): $(SRC)
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(SRC) $(LDFLAGS)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	sudo cp $(TARGET) /usr/local/bin/

run: $(TARGET)
	sudo ./$(TARGET)

.PHONY: all clean install run
