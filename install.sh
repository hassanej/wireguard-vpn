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

echo "[2/10] Installing dependencies..."
apt install -y curl ufw ca-certificates jq python3

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

HASH_OUTPUT=$(docker run --rm ghcr.io/wg-easy/wg-easy:latest wgpw "$WG_PASSWORD")

# Extract only the bcrypt hash from:
# PASSWORD_HASH='$2a$12$...'
PASSWORD_HASH=$(printf '%s\n' "$HASH_OUTPUT" | sed -n "s/^PASSWORD_HASH='\(.*\)'$/\1/p")

# Escape $ for Docker Compose
PASSWORD_HASH=$(printf '%s\n' "$PASSWORD_HASH" | sed 's/\$/$$/g')

if [[ ! "$PASSWORD_HASH" =~ ^\$\$2[aby]\$\$ ]]; then
    echo "Failed to generate a valid password hash."
    exit 1
fi

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
ufw allow 8080/tcp >/dev/null
ufw allow 51820/udp >/dev/null
ufw allow 51821/tcp >/dev/null
ufw --force enable >/dev/null

echo "[10/10] Starting WireGuard..."

cd /opt/wg-easy

docker compose pull
docker compose up -d
docker compose ps

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

echo "Waiting for API..."

for i in {1..60}; do
    if curl -fs \
        -H "Authorization: ${WG_PASSWORD}" \
        http://127.0.0.1:51821/api/wireguard/client >/dev/null; then
        break
    fi

    sleep 1
done

if ! curl -fs \
    -H "Authorization: ${WG_PASSWORD}" \
    http://127.0.0.1:51821/api/wireguard/client >/dev/null; then
    echo "WireGuard API failed to start."
    exit 1
fi

echo
echo "Creating VPN client..."

CLIENT_NAME="Client 1"

# Check whether the client already exists
CLIENT_ID=$(
curl -s \
    -H "Authorization: ${WG_PASSWORD}" \
    http://127.0.0.1:51821/api/wireguard/client \
| jq -r '.[] | select(.name=="'"${CLIENT_NAME}"'") | .id'
)

# Create it if it doesn't exist
if [ -z "$CLIENT_ID" ]; then
    curl -s \
        -H "Authorization: ${WG_PASSWORD}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"name\":\"${CLIENT_NAME}\"}" \
        http://127.0.0.1:51821/api/wireguard/client >/dev/null

    CLIENT_ID=$(
    curl -s \
        -H "Authorization: ${WG_PASSWORD}" \
        http://127.0.0.1:51821/api/wireguard/client \
    | jq -r '.[] | select(.name=="'"${CLIENT_NAME}"'") | .id'
    )
fi

if [ -z "$CLIENT_ID" ]; then
    echo "Failed to create VPN client."
    exit 1
fi

rm -rf /opt/wg-download
mkdir -p /opt/wg-download

curl -s \
    -H "Authorization: ${WG_PASSWORD}" \
    "http://127.0.0.1:51821/api/wireguard/client/${CLIENT_ID}/configuration" \
    -o "/opt/wg-download/${CLIENT_NAME}.conf"

if [ ! -s "/opt/wg-download/${CLIENT_NAME}.conf" ]; then
    echo "Failed to download client configuration."
    exit 1
fi

if ! grep -q "PrivateKey" "/opt/wg-download/${CLIENT_NAME}.conf"; then
    echo "Downloaded configuration is invalid."
    exit 1
fi

echo
echo "Starting temporary download server..."

(
cd /opt/wg-download

python3 <<'PY'
import http.server
import socketserver
import threading
import os

PORT = 8080
FILE = "Client 1.conf"

class Handler(http.server.SimpleHTTPRequestHandler):
    def copyfile(self, source, outputfile):
        try:
            super().copyfile(source, outputfile)
        except (BrokenPipeError, ConnectionResetError):
            return

        try:
            os.remove(FILE)
        except FileNotFoundError:
            pass

        threading.Thread(target=self.server.shutdown, daemon=True).start()

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

with ReusableTCPServer(("", PORT), Handler) as httpd:
    httpd.handle_request()
PY

rm -rf /opt/wg-download
) >/dev/null 2>&1 &

echo
echo "========================================="
echo "          SUCCESS"
echo "========================================="
echo
echo "Dashboard:"
echo "http://${PUBLIC_IP}:51821"
echo
echo "Download:"
echo
echo "http://${PUBLIC_IP}:8080/Client%201.conf"
echo
echo
