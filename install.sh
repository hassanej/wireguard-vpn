#!/usr/bin/env bash

set -Eeuo pipefail
set +x

readonly WG_HOST="wireguardhsn.duckdns.org"
readonly DUCKDNS_DOMAIN="wireguardhsn"
readonly WG_PASSWORD="wireguardhsn"
readonly CLIENT_NAME="iPhone"
readonly WG_EASY_IMAGE="ghcr.io/wg-easy/wg-easy:14"
readonly CADDY_IMAGE="caddy:2.10.0-alpine"
readonly INSTALL_DIR="/opt/wg-easy"
readonly DATA_DIR="${INSTALL_DIR}/data"
readonly STATE_RELATIVE_PATH="state/wg-easy-data.tar.gz"

REPO_ROOT=""
AUTH_HEADER=""
PUBLIC_IP=""
STATE_PRESENT=false

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

on_error() {
    local exit_code=$?
    echo >&2
    echo "Installation failed (exit ${exit_code})." >&2
    if command -v docker >/dev/null 2>&1 && [ -f "${INSTALL_DIR}/compose.yaml" ]; then
        docker compose -f "${INSTALL_DIR}/compose.yaml" ps >&2 || true
    fi
    exit "$exit_code"
}

trap on_error ERR

require_secret() {
    local name=$1
    [ -n "${!name:-}" ] || fail "${name} must be set in the environment."
}

github_git() {
    git -c http.extraHeader="Authorization: Basic ${AUTH_HEADER}" "$@"
}

wait_for_dns() {
    local resolved=""

    echo "Waiting for ${WG_HOST} to resolve to ${PUBLIC_IP}..."
    for _ in {1..60}; do
        resolved=$(dig +short A "$WG_HOST" @1.1.1.1 | tail -n 1)
        if [ "$resolved" = "$PUBLIC_IP" ]; then
            echo "DuckDNS is resolving correctly."
            return 0
        fi
        sleep 5
    done

    fail "DNS did not update to ${PUBLIC_IP} within five minutes."
}

wait_for_wg_easy() {
    local status=""

    echo "Waiting for WireGuard to become healthy..."
    for _ in {1..60}; do
        status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' wg-easy 2>/dev/null || true)
        if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
            if curl -fsS -H "Authorization: ${WG_PASSWORD}" \
                http://127.0.0.1:51821/api/wireguard/client >/dev/null; then
                return 0
            fi
        fi
        sleep 2
    done

    docker logs wg-easy >&2 || true
    fail "WireGuard or its management API did not become ready."
}

ensure_ios_client() {
    local clients client_id

    clients=$(curl -fsS -H "Authorization: ${WG_PASSWORD}" \
        http://127.0.0.1:51821/api/wireguard/client)
    client_id=$(printf '%s' "$clients" | jq -r --arg name "$CLIENT_NAME" \
        '.[] | select(.name == $name) | .id' | head -n 1)

    if [ -n "$client_id" ]; then
        echo "Permanent iOS client already exists; preserving it."
        return 0
    fi

    echo "Creating permanent iOS client..."
    curl -fsS \
        -H "Authorization: ${WG_PASSWORD}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"name\":\"${CLIENT_NAME}\"}" \
        http://127.0.0.1:51821/api/wireguard/client >/dev/null

    clients=$(curl -fsS -H "Authorization: ${WG_PASSWORD}" \
        http://127.0.0.1:51821/api/wireguard/client)
    client_id=$(printf '%s' "$clients" | jq -r --arg name "$CLIENT_NAME" \
        '.[] | select(.name == $name) | .id' | head -n 1)
    [ -n "$client_id" ] || fail "The permanent iOS client could not be created."
}

back_up_first_identity() {
    local state_path="${REPO_ROOT}/${STATE_RELATIVE_PATH}"

    echo "Saving the permanent WireGuard identity to the private repository..."
    mkdir -p "$(dirname "$state_path")"
    docker compose -f "${INSTALL_DIR}/compose.yaml" stop wg-easy
    tar -C "$DATA_DIR" -czf "$state_path" .
    chmod 600 "$state_path"
    docker compose -f "${INSTALL_DIR}/compose.yaml" start wg-easy
    wait_for_wg_easy

    git -C "$REPO_ROOT" add "$STATE_RELATIVE_PATH"
    if git -C "$REPO_ROOT" diff --cached --quiet; then
        fail "No WireGuard state was available to save."
    fi

    git -C "$REPO_ROOT" -c user.name="WireGuard Installer" \
        -c user.email="wireguard-installer@localhost" \
        commit -m "Persist WireGuard server and iOS identity"

    if ! github_git -C "$REPO_ROOT" push origin HEAD:main; then
        fail "The permanent identity was created locally but could not be pushed. Check that GITHUB_TOKEN has Contents read/write access, then rerun this installer on the same server."
    fi

    echo "Permanent identity saved to ${STATE_RELATIVE_PATH}."
}

if [ "${EUID}" -ne 0 ]; then
    fail "Run this installer as root (sudo --preserve-env=GITHUB_TOKEN,DUCKDNS_TOKEN bash install.sh)."
fi

require_secret GITHUB_TOKEN
require_secret DUCKDNS_TOKEN

[ -r /etc/os-release ] || fail "This installer requires Ubuntu."
# shellcheck disable=SC1091
source /etc/os-release
[ "${ID:-}" = "ubuntu" ] || fail "This installer supports Ubuntu only."
command -v systemctl >/dev/null 2>&1 || fail "A systemd-based Ubuntu server is required."

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    fail "install.sh must be run from its Git repository clone."

AUTH_HEADER=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 | tr -d '\n')
github_git -C "$REPO_ROOT" ls-remote --exit-code origin HEAD >/dev/null || \
    fail "GITHUB_TOKEN cannot read the private repository."

export DEBIAN_FRONTEND=noninteractive

echo "========================================="
echo "  Persistent WireGuard VPN Installer"
echo "========================================="

echo "[1/10] Installing system dependencies..."
apt-get update
apt-get install -y ca-certificates curl dnsutils git jq tar ufw

echo "[2/10] Installing and starting Docker..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
until docker info >/dev/null 2>&1; do sleep 2; done
if ! docker compose version >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin
fi

echo "[3/10] Detecting the Vultr public IPv4 address..."
PUBLIC_IP=$(curl -4 -fsSL https://api.ipify.org)
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
    fail "Could not detect a valid public IPv4 address."
echo "Public IPv4: ${PUBLIC_IP}"

echo "[4/10] Updating DuckDNS..."
DUCKDNS_RESULT=$(curl -fsS --get \
    --data-urlencode "domains=${DUCKDNS_DOMAIN}" \
    --data-urlencode "token=${DUCKDNS_TOKEN}" \
    --data-urlencode "ip=${PUBLIC_IP}" \
    https://www.duckdns.org/update)
[ "$DUCKDNS_RESULT" = "OK" ] || fail "DuckDNS rejected the update."
wait_for_dns

echo "[5/10] Enabling forwarding and configuring the firewall..."
cat >/etc/sysctl.d/99-wireguard.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 51820/udp >/dev/null
ufw --force delete allow 51821/tcp >/dev/null 2>&1 || true
ufw --force delete allow 8080/tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null

echo "[6/10] Preparing persistent WireGuard state..."
mkdir -p "$DATA_DIR" "${INSTALL_DIR}/caddy_data" "${INSTALL_DIR}/caddy_config"
chmod 700 "$DATA_DIR"
if [ -s "${REPO_ROOT}/${STATE_RELATIVE_PATH}" ]; then
    STATE_PRESENT=true
    echo "Restoring the permanent server and iOS identity from GitHub..."
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    tar -C "$DATA_DIR" -xzf "${REPO_ROOT}/${STATE_RELATIVE_PATH}"
fi

echo "[7/10] Creating pinned service configuration..."
docker pull "$WG_EASY_IMAGE"
docker pull "$CADDY_IMAGE"
HASH_OUTPUT=$(docker run --rm "$WG_EASY_IMAGE" wgpw "$WG_PASSWORD")
PASSWORD_HASH=$(printf '%s\n' "$HASH_OUTPUT" | sed -n "s/^PASSWORD_HASH='\(.*\)'$/\1/p")
[ -n "$PASSWORD_HASH" ] || fail "Could not generate the dashboard password hash."
PASSWORD_HASH=${PASSWORD_HASH//\$/\$\$}

cat >"${INSTALL_DIR}/compose.yaml" <<EOF
services:
  wg-easy:
    image: ${WG_EASY_IMAGE}
    container_name: wg-easy
    restart: unless-stopped
    environment:
      LANG: en
      PASSWORD_HASH: "${PASSWORD_HASH}"
      WG_HOST: ${WG_HOST}
      WG_PORT: "51820"
      WG_PERSISTENT_KEEPALIVE: "25"
    volumes:
      - ./data:/etc/wireguard
    ports:
      - "51820:51820/udp"
      - "127.0.0.1:51821:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      net.ipv4.ip_forward: "1"
      net.ipv4.conf.all.src_valid_mark: "1"

  caddy:
    image: ${CADDY_IMAGE}
    container_name: wireguard-caddy
    restart: unless-stopped
    depends_on:
      - wg-easy
    ports:
      - "80:80/tcp"
      - "443:443/tcp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy_data:/data
      - ./caddy_config:/config
EOF

cat >"${INSTALL_DIR}/Caddyfile" <<EOF
${WG_HOST} {
    reverse_proxy wg-easy:51821
}
EOF

docker compose -f "${INSTALL_DIR}/compose.yaml" config >/dev/null

echo "[8/10] Starting WireGuard and HTTPS..."
docker compose -f "${INSTALL_DIR}/compose.yaml" up -d --remove-orphans
wait_for_wg_easy

echo "[9/10] Ensuring the permanent iOS client exists..."
ensure_ios_client
if [ "$STATE_PRESENT" = false ]; then
    back_up_first_identity
fi

echo "[10/10] Verifying HTTPS and automatic startup..."
for _ in {1..60}; do
    if curl -fsS "https://${WG_HOST}/" >/dev/null; then
        HTTPS_READY=true
        break
    fi
    sleep 5
done
[ "${HTTPS_READY:-false}" = true ] || {
    docker logs wireguard-caddy >&2 || true
    fail "HTTPS did not become ready within five minutes."
}

docker compose -f "${INSTALL_DIR}/compose.yaml" ps
docker image prune -f >/dev/null 2>&1 || true

unset GITHUB_TOKEN DUCKDNS_TOKEN AUTH_HEADER

echo
echo "========================================="
echo "                 SUCCESS"
echo "========================================="
echo "Dashboard: https://${WG_HOST}"
echo "Password:  ${WG_PASSWORD}"
echo "iOS client: ${CLIENT_NAME}"
echo
echo "Open the dashboard, sign in, and scan the ${CLIENT_NAME} QR code once."
echo "The same iOS tunnel will work after future server replacements."
