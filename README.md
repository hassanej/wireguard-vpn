# Persistent WireGuard VPN for Vultr

This repository installs one persistent WireGuard VPN on an Ubuntu Vultr server.

It configures:

- VPN endpoint: `wireguardhsn.duckdns.org:51820`
- HTTPS wg-easy dashboard: `https://wireguardhsn.duckdns.org`
- Dashboard password: `wireguardhsn`
- One permanent client named `iPhone`
- Automatic startup after reboot
- Restoration of the same WireGuard server and iPhone identity on replacement servers

## Security warning

The following archive contains unencrypted WireGuard private keys:

text
state/wg-easy-data.tar.gz