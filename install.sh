#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo; echo "Installation failed."; exit 1' ERR

export DEBIAN_FRONTEND=noninteractive

echo "========================================="
echo "      WireGuard VPN Installer"
echo "========================================="

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root."
    exit 1
fi

echo "Checking internet connectivity..."

if ! curl -fsSL https://api.ipify.org >/dev/null; then
    echo "No internet connection detected."
    exit 1
fi

if [ -f /opt/wg-easy/compose.yaml ]; then
    echo
    echo "An existing WireGuard installation was found."
    read -rp "Overwrite it? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
fi

echo

while true; do
    read -rsp "Enter WireGuard dashboard password: " WG_PASSWORD
    echo
    read -rsp "Confirm password: " WG_CONFIRM
    echo

    [[ "$WG_PASSWORD" == "$WG_CONFIRM" ]] && break

    echo
    echo "Passwords do not match."
    echo
done

echo
echo "[1/10] Updating system..."
apt update
apt upgrade -y

echo "[2/10] Installing dependencies..."
apt install -y curl ufw ca-certificates

echo "[3/10] Installing Docker..."

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

docker --version >/dev/null

echo "[4/10] Starting Docker..."

systemctl enable docker
systemctl start docker

until docker info >/dev/null 2>&1; do
    echo "Waiting for Docker..."
    sleep 2
done

echo "Checking Docker Compose..."

if ! docker compose version >/dev/null 2>&1; then
    apt update
    apt install -y docker-compose-plugin
fi

echo "[5/10] Enabling IPv4 forwarding..."

cat >/etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl --system >/dev/null

echo "[6/10] Detecting public IP..."

PUBLIC_IP=$(
    curl -4 -fsSL https://api.ipify.org ||
    curl -4 -fsSL https://ifconfig.me ||
    curl -4 -fsSL https://icanhazip.com
)

PUBLIC_IP=$(echo "$PUBLIC_IP" | tr -d '\n')

echo "Public IP: ${PUBLIC_IP}"

echo "[7/10] Generating password hash..."

PASSWORD_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy:latest wgpw "$WG_PASSWORD")
PASSWORD_HASH="${PASSWORD_HASH//$/\$\$}"

mkdir -p /opt/wg-easy

echo "[8/10] Creating Docker Compose configuration..."

cat >/opt/wg-easy/compose.yaml <<EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
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

echo "[9/10] Configuring firewall..."

ufw allow 22/tcp >/dev/null
ufw allow 51820/udp >/dev/null
ufw allow 51821/tcp >/dev/null
ufw --force enable >/dev/null

echo "[10/10] Starting WireGuard..."

cd /opt/wg-easy

docker compose pull
docker compose up -d

echo
echo "Waiting for WireGuard to become healthy..."

STATUS=""

for i in {1..30}; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' wg-easy 2>/dev/null || true)

    if [[ "$STATUS" == "healthy" ]]; then
        break
    fi

    sleep 2
done

if [[ "$STATUS" != "healthy" ]]; then
    echo
    echo "WireGuard failed to become healthy."
    echo
    docker logs wg-easy
    exit 1
fi

docker image prune -f >/dev/null 2>&1 || true

echo
echo "========================================="
echo "          SUCCESS"
echo "========================================="
echo
echo "Dashboard:"
echo "http://${PUBLIC_IP}:51821"
echo
echo "WireGuard Port:"
echo "51820/UDP"
echo
echo "SSH:"
echo "ssh root@${PUBLIC_IP}"
echo
echo "Next Steps:"
echo "1. Open the dashboard."
echo "2. Log in using the password you entered."
echo "3. Create a client."
echo "4. Scan the QR code with the WireGuard app."
echo
echo "========================================="
