#!/usr/bin/env bash
set -Eeuo pipefail

echo "========================================="
echo "   WireGuard VPN Installer"
echo "========================================="

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root."
    exit 1
fi

read -rsp "Enter WireGuard dashboard password: " WG_PASSWORD
echo
echo

echo "[1/8] Updating system..."
apt update
apt upgrade -y

echo "[2/8] Installing dependencies..."
apt install -y curl ufw ca-certificates

echo "[3/8] Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

echo "[4/8] Installing Docker Compose plugin..."
if ! docker compose version >/dev/null 2>&1; then
    apt install -y docker-compose-plugin
fi

echo "[5/8] Detecting public IP..."
PUBLIC_IP=$(curl -4 -fsSL https://api.ipify.org)

echo "[6/8] Generating password hash..."
PASSWORD_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy:15 wgpw "$WG_PASSWORD")
PASSWORD_HASH="${PASSWORD_HASH//$/\$\$}"

mkdir -p /opt/wg-easy

cat >/opt/wg-easy/compose.yaml <<EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    restart: unless-stopped

    environment:
      - LANG=en
      - PASSWORD_HASH=${PASSWORD_HASH}
      - WG_HOST=${PUBLIC_IP}

    volumes:
      - ./data:/etc/wireguard

    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"

    cap_add:
      - NET_ADMIN
      - SYS_MODULE

    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF

echo "[7/8] Configuring firewall..."

ufw allow 22/tcp >/dev/null
ufw allow 51820/udp >/dev/null
ufw allow 51821/tcp >/dev/null
ufw --force enable

echo "[8/8] Starting WireGuard..."

cd /opt/wg-easy
docker compose pull
docker compose up -d

echo
echo "========================================="
echo " Installation Complete"
echo "========================================="
echo
echo "Dashboard:"
echo "http://${PUBLIC_IP}:51821"
echo
echo "Password:"
echo "(the password you entered)"
echo
echo "WireGuard Port: 51820/UDP"
echo
echo "========================================="
