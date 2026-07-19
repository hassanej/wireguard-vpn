# Persistent WireGuard VPN for Vultr

This repository installs a single persistent WireGuard VPN on an Ubuntu Vultr
server. It configures:

- VPN endpoint: `wireguardhsn.duckdns.org:51820`
- HTTPS wg-easy dashboard: `https://wireguardhsn.duckdns.org`
- Dashboard password: `wireguardhsn`
- One permanent client named `iPhone`
- Automatic startup after reboot
- Automatic restoration of the same iOS keys on a replacement server

## Requirements

- A fresh, systemd-based Ubuntu Vultr server
- This GitHub repository must remain private
- A fine-grained GitHub token with **Contents: Read and write** access to this repository
- The DuckDNS token for the `wireguardhsn` subdomain

The GitHub token needs write access only because the first installation commits
the generated WireGuard identity to `state/wg-easy-data.tar.gz`. That archive is
not encrypted and contains private WireGuard keys. Anyone who can read the
repository can impersonate the VPN server or client.

## Quick-paste installation

Connect to the Vultr server as `root`, paste this block, and enter both tokens at
the hidden prompts. The tokens are not added to shell history, Git configuration,
Docker configuration, or tracked files.

```bash
read -rsp "GitHub token: " GITHUB_TOKEN; echo
read -rsp "DuckDNS token: " DUCKDNS_TOKEN; echo
export GITHUB_TOKEN DUCKDNS_TOKEN
AUTH=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
git -c http.extraHeader="Authorization: Basic $AUTH" clone https://github.com/hassanej/wireguard-vpn.git
unset AUTH
cd wireguard-vpn
sudo --preserve-env=GITHUB_TOKEN,DUCKDNS_TOKEN bash install.sh
```

## First installation

The installer updates DuckDNS, starts WireGuard and the HTTPS dashboard, creates
the permanent `iPhone` client, then commits the generated WireGuard state to the
private repository's `main` branch.

After it succeeds:

1. Open `https://wireguardhsn.duckdns.org`.
2. Sign in with `wireguardhsn`.
3. Open the `iPhone` client and scan its QR code using the WireGuard iOS app.

Keep that tunnel on the iPhone. It is the permanent profile.

## Reinstalling or replacing the server

Run the same quick-paste block on the replacement Vultr server. The installer
restores `state/wg-easy-data.tar.gz` before WireGuard starts and moves DuckDNS to
the new public IPv4 address. Do not delete or recreate the `iPhone` client in the
dashboard; doing so would invalidate the profile already installed on iOS.

It can take a few minutes for DuckDNS and the HTTPS certificate to become ready.
Once installation reports success, activating the existing iOS tunnel will
connect it to the replacement server automatically.

## Open ports

- `22/tcp`: SSH
- `80/tcp`: HTTPS certificate issuance and redirect
- `443/tcp`: HTTPS dashboard
- `51820/udp`: WireGuard

The wg-easy service port `51821` is bound to localhost only. The former temporary
download port `8080` is not used.
