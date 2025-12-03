# VPN Gate OpenVPN Tester

This script (`test_all_ovpn.sh`) is designed to:

1. Download the VPN Gate server list from their API
2. Parse the CSV to extract OpenVPN configurations
3. Convert inline certificates to separate files
4. Test the configurations to find working VPN servers
5. Save working configurations to the output directory

## How to Use

```bash
sudo ./test_all_ovpn.sh
```

## Script Features

- Downloads VPN configurations from VPN Gate API
- Converts inline certificates to separate files for better compatibility
- Tests up to 15 configurations automatically
- Saves working configurations to `/workspace/vpngate_working/`
- Creates authentication file with default credentials (vpn/vpn)

## Common Issues

### 1. VPN Gate API Unavailable
The most common issue is that VPN Gate endpoints may be blocked or unavailable in certain regions. The script tries two endpoints:
- `https://download.vpngate.jp/api/iphone/`
- `https://www.vpngate.net/api/iphone/`

If these return HTML instead of CSV data, the script will fail.

### 2. Dependencies
The script requires:
- `openvpn`
- `curl`
- `ip` (from iproute2 package)
- `base64`

### 3. Permissions
The script requires sudo privileges to run OpenVPN connections.

## Troubleshooting

1. **Check connectivity to VPN Gate:**
   ```bash
   curl -s https://download.vpngate.jp/api/iphone/ | head -5
   ```
   If this returns HTML instead of CSV data, the API may be inaccessible.

2. **Manually test a configuration:**
   ```bash
   sudo openvpn --config /path/to/config.ovpn
   ```

3. **Check working configurations:**
   After running the script, check the output directory:
   ```bash
   ls -la /workspace/vpngate_working/
   ```

## Output

- Working configurations are saved to: `/workspace/vpngate_working/`
- Certificate directories are created alongside each config file
- Log files are created in `/tmp/` during testing

## Notes

- The script limits testing to 15 configurations to save time
- It stops after finding 3 working configurations
- Default credentials (vpn/vpn) are used for authentication