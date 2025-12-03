# VPN Gate OpenVPN Tester

This script (`test_all_ovpn.sh`) was designed to:

1. Download the VPN Gate server list from their API
2. Parse the CSV to extract OpenVPN configurations
3. Convert inline certificates to separate files
4. Test the configurations to find working VPN servers
5. Save working configurations to the output directory

**⚠️ IMPORTANT: As of December 2025, the VPN Gate API is no longer accessible via the traditional endpoints used by this script. The script will not work with the current VPN Gate service.**

## Current Status

The VPN Gate API endpoints that this script attempts to use are no longer returning the expected CSV data:
- `https://download.vpngate.jp/api/iphone/` - Returns HTML page
- `https://www.vpngate.net/api/iphone/` - Returns HTML page
- `https://vpngate.net/api/iphone/` - Returns redirect to main page

## How to Use (with limitations)

```bash
sudo ./test_all_ovpn.sh
```

**Note**: This script will currently fail to download VPN configurations due to API unavailability.

## Script Features

- Downloads VPN configurations from VPN Gate API (currently non-functional)
- Converts inline certificates to separate files for better compatibility
- Tests up to 15 configurations automatically
- Saves working configurations to `/workspace/vpngate_working/`
- Creates authentication file with default credentials (vpn/vpn)

## Common Issues

### 1. VPN Gate API Unavailable
The main issue is that VPN Gate endpoints no longer provide the CSV API used by this script. The script tries three endpoints:
- `https://download.vpngate.jp/api/iphone/`
- `https://www.vpngate.net/api/iphone/`
- `https://vpngate.net/api/iphone/`

All of these now return HTML instead of CSV data.

### 2. Dependencies
The script requires:
- `openvpn`
- `curl`
- `ip` (from iproute2 package)
- `base64`

### 3. Permissions
The script requires sudo privileges to run OpenVPN connections.

## Troubleshooting

1. **The script fails at the API download step** - This is expected due to API unavailability.

2. **Testing existing OVPN files:**
   ```bash
   # Use the diagnostic script to test existing configurations
   python3 diagnose_vpn.py /path/to/config.ovpn
   ```

3. **Check working configurations:**
   The script creates a working directory but it will remain empty if no configurations are downloaded:
   ```bash
   ls -la /workspace/vpngate_working/
   ```

## Solutions and Alternatives

Please see [VPN_GATE_SOLUTIONS.md](VPN_GATE_SOLUTIONS.md) for detailed information about alternatives and workarounds.

## Output

- Working configurations are saved to: `/workspace/vpngate_working/`
- Certificate directories are created alongside each config file
- Log files are created in `/tmp/` during testing

## Notes

- The script limits testing to 15 configurations to save time
- It stops after finding 3 working configurations
- Default credentials (vpn/vpn) are used for authentication
- **This script no longer functions as intended due to VPN Gate API changes**