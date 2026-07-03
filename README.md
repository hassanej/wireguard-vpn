# WireGuard VPN Installer

Deploy a fresh Ubuntu 24.04 VPS with **wg-easy** in a few minutes.

## Requirements

- A new Ubuntu 24.04 VPS
- Root SSH access
- Internet connection

## Installation

SSH into your server:

```bash
ssh root@YOUR_SERVER_IP
```

Install Git:

```bash
apt update
apt install -y git
```

Clone this repository:

```bash
git clone https://github.com/hassanej/wireguard-vpn.git
cd wireguard-vpn
```

Run the installer:

```bash
bash install.sh
```

## During installation

The installer will:

- Update Ubuntu
- Install Docker
- Configure the firewall
- Detect your server's public IP
- Ask for your WireGuard dashboard password
- Install and start wg-easy

## Access the dashboard

When the installer finishes, open:

```
http://YOUR_SERVER_IP:51821
```

Log in using the password you entered during installation.

## Create your VPN

1. Click **New Client**
2. Give the client a name (e.g. iPhone, MacBook)
3. Click **Create**
4. Scan the QR code with the WireGuard app

You're now connected through your VPS.
