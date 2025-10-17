#!/usr/bin/env bash
set -Eeuo pipefail

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Jellyfin + qBittorrent + Sonarr + Radarr + Prowlarr + Jellyseerr"
echo "  Caddy (TLS 1.3, HTTP/3, headers, BasicAuth) + Fail2ban + No-IP (ddclient REQUIRED)"
echo "  Hardened Installer for Linux Mint 22.2 / Ubuntu 24.04"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

if ! grep -Eq 'Linux Mint 22|Ubuntu 24\.04' /etc/os-release; then
  echo "⚠ This script targets Linux Mint 22.2 or Ubuntu 24.04 (noble). Exiting."
  exit 1
fi
[[ $EUID -eq 0 ]] || { echo "❌ Run as root: sudo bash $0"; exit 1; }

PRIMARY_USER="$(logname 2>/dev/null || echo "${SUDO_USER:-}")"
[[ -n "$PRIMARY_USER" ]] || { echo "❌ Could not detect primary user."; exit 1; }

read -rp "Domain for HTTPS (e.g. dexter.gotdns.ch): " DOMAIN
read -rp "Let's Encrypt email: " EMAIL
read -rp "No-IP username (email): " NOIP_USERNAME
read -rsp "No-IP password: " NOIP_PASSWORD; echo

echo "BasicAuth will protect qBit/Sonarr/Radarr/Prowlarr/Jellyseerr (Jellyfin stays public)."
read -rp "BasicAuth username [admin]: " BA_USER
BA_USER="${BA_USER:-admin}"
read -rsp "BasicAuth password (won't echo): " BA_PASS; echo

STACK_DIR="/opt/jellyfin-stack"
DATA_ROOT="/srv/media"
CFG="${DATA_ROOT}/config"
CADDY_DIR="${CFG}/caddy"
CADDYFILE="${CADDY_DIR}/Caddyfile"
CADDY_LOG_DIR="/var/log/caddy"
TZ="${TZ:-Europe/Bucharest}"

mkdir -p "$STACK_DIR" "$DATA_ROOT"/{downloads,library/{Movies,TV},config} "$CADDY_LOG_DIR"
chown -R "$PRIMARY_USER:$PRIMARY_USER" "$STACK_DIR" "$DATA_ROOT"
chmod -R 775 "$STACK_DIR" "$DATA_ROOT"
chown root:adm "$CADDY_LOG_DIR" || true
chmod 750 "$CADDY_LOG_DIR" || true

PUID="$(id -u "$PRIMARY_USER")"
PGID="$(id -g "$PRIMARY_USER")"

echo "▶ Updating system & installing base packages..."
apt-get update -y
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban wget unzip make gcc

echo "▶ Installing Docker Engine (noble repo)..."
grep -rl "download.docker.com" /etc/apt/sources.list* /etc/apt/sources.list.d 2>/dev/null | xargs -r rm -f || true
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable
EOF
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$PRIMARY_USER" || true

echo "▶ Installing & configuring ddclient for No-IP (REQUIRED)..."
apt-get install -y ddclient
cat >/etc/ddclient.conf <<CFG
protocol=dyndns2
use=web, web=checkip.amazonaws.com/, web-skip='Current IP Address:'
server=dynupdate.no-ip.com
ssl=yes
login=${NOIP_USERNAME}
password='${NOIP_PASSWORD}'
${DOMAIN}
CFG
chmod 600 /etc/ddclient.conf
sed -i 's/^#*run_daemon=.*/run_daemon="true"/' /etc/default/ddclient
sed -i 's/^#*daemon_interval=.*/daemon_interval="300"/' /etc/default/ddclient
systemctl enable --now ddclient

echo "▶ Writing environment file..."
cat > "${STACK_DIR}/.env" <<EOF
TZ=${TZ}
PUID=${PUID}
PGID=${PGID}
DATA_ROOT=${DATA_ROOT}
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${EMAIL}
EOF

echo "▶ Generating bcrypt hash for Caddy BasicAuth..."
HASH="$(docker run --rm caddy:2 caddy hash-password --plaintext "$BA_PASS")"

echo "▶ Writing docker-compose.yml (ONLY Caddy exposes 80/443)..."
cat > "${STACK_DIR}/docker-compose.yml" <<'YML'
x-env: &core_env
  TZ: ${TZ}
  PUID: ${PUID}
  PGID: ${PGID}

networks:
  media-net:

volumes:
  caddy_data:
  caddy_config:

services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment: *core_env
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8096/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 15
    volumes:
      - ${DATA_ROOT}/config/jellyfin:/config
      - ${DATA_ROOT}/library/TV:/data/tvshows
      - ${DATA_ROOT}/library/Movies:/data/movies
      - ${DATA_ROOT}/downloads:/downloads
    networks: [media-net]
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      <<: *core_env
      WEBUI_PORT: 8080
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8080/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 20
    volumes:
      - ${DATA_ROOT}/config/qbit:/config
      - ${DATA_ROOT}/downloads:/downloads
    networks: [media-net]
    restart: unless-stopped
    entrypoint: >
      /bin/sh -c '
        if [ ! -f /config/qBittorrent/qBittorrent.conf ]; then
          mkdir -p /config/qBittorrent;
          echo '\''WebUI\Username=admin'\'' > /config/qBittorrent/qBittorrent.conf;
          echo '\''WebUI\Password_PBKDF2=@ByteArray(PBKDF2$sha256$100000$frTE5dWZo2B5Phjj7ZblDQ==$WE+pssfy9sF36AJdj1k1Z6ioBS2UpCsjNeAkni5aR3E=)'\'' >> /config/qBittorrent/qBittorrent.conf;
          echo '\''WebUI\Enabled=true'\'' >> /config/qBittorrent/qBittorrent.conf;
          echo '\''WebUI\Port=8080'\'' >> /config/qBittorrent/qBittorrent.conf;
          echo '\''WebUI\Address=*'\'' >> /config/qBittorrent/qBittorrent.conf;
          echo '\''WebUI\HostHeaderValidation=false'\'' >> /config/qBittorrent/qBittorrent.conf;
          echo '\''WebUI\MaxAuthenticationFailCount=20'\'' >> /config/qBittorrent/qBittorrent.conf;
          echo '\''WebUI\TrustedReverseProxies=172.16.0.0/12,192.168.0.0/16,10.0.0.0/8'\'' >> /config/qBittorrent/qBittorrent.conf;
        fi;
        exec /init
      '

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment: *core_env
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:9696/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10
    volumes:
      - ${DATA_ROOT}/config/prowlarr:/config
    networks: [media-net]
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment: *core_env
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:8989/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10
    volumes:
      - ${DATA_ROOT}/config/sonarr:/config
      - ${DATA_ROOT}/library/TV:/tv
      - ${DATA_ROOT}/downloads:/downloads
    networks: [media-net]
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment: *core_env
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:7878/ || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 10
    volumes:
      - ${DATA_ROOT}/config/radarr:/config
      - ${DATA_ROOT}/library/Movies:/movies
      - ${DATA_ROOT}/downloads:/downloads
    networks: [media-net]
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    environment: *core_env
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:5055/api/v1/status || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 15
    volumes:
      - ${DATA_ROOT}/config/jellyseerr:/app/config
    networks: [media-net]
    restart: unless-stopped

  caddy:
    image: caddy:2
    container_name: caddy
    depends_on:
      - jellyfin
      - qbittorrent
      - sonarr
      - radarr
      - prowlarr
      - jellyseerr
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DOMAIN=${DOMAIN}
      - LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
    volumes:
      - ${DATA_ROOT}/config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
      - /var/log/caddy:/var/log/caddy
    networks: [media-net]
    restart: unless-stopped
YML

echo "▶ Writing hardened Caddyfile..."
mkdir -p "${CADDY_DIR}"
cat > "${CADDYFILE}" <<EOF
{
  email ${EMAIL}
  servers {
    protocol {
      experimental_http3
    }
    tls {
      ciphers TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384
    }
  }
}

https://${DOMAIN} {
  encode gzip zstd

  header {
    Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    X-Frame-Options "DENY"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "no-referrer-when-downgrade"
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
    Content-Security-Policy "default-src 'self'; frame-ancestors 'none';"
  }

  log {
    output file /var/log/caddy/access.log
    format single_field common_log
  }

  # Public: Jellyfin
  handle_path /jellyfin/* {
    reverse_proxy jellyfin:8096
  }

  # Protected apps (BasicAuth blocks — FIXED syntax)
  basicauth /qbit/* {
    ${BA_USER} ${HASH}
  }
  handle_path /qbit/* {
    reverse_proxy qbittorrent:8080
  }

  basicauth /sonarr/* {
    ${BA_USER} ${HASH}
  }
  handle_path /sonarr/* {
    reverse_proxy sonarr:8989
  }

  basicauth /radarr/* {
    ${BA_USER} ${HASH}
  }
  handle_path /radarr/* {
    reverse_proxy radarr:7878
  }

  basicauth /prowlarr/* {
    ${BA_USER} ${HASH}
  }
  handle_path /prowlarr/* {
    reverse_proxy prowlarr:9696
  }

  basicauth /seerr/* {
    ${BA_USER} ${HASH}
  }
  handle_path /seerr/* {
    reverse_proxy jellyseerr:5055
  }

  handle {
    respond "✅ Secure media stack online. Try /jellyfin, /qbit, /sonarr, /radarr, /prowlarr, /seerr" 200
  }
}
EOF

echo "▶ Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 22/tcp
ufw --force enable

echo "▶ Setting up Fail2ban jail for Caddy..."
mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d
cat > /etc/fail2ban/jail.d/caddy-login.conf <<'JAIL'
[caddy-login]
enabled   = true
filter    = caddy-login
logpath   = /var/log/caddy/access.log
maxretry  = 5
findtime  = 600
bantime   = 3600
JAIL
cat > /etc/fail2ban/filter.d/caddy-login.conf <<'FIL'
[Definition]
# CLF example: 1.2.3.4 - - [date] "POST /path HTTP/1.1" 401 0
failregex = ^<HOST> [^"]* "POST .*" (401|403) .*
ignoreregex =
FIL
systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

echo "▶ Starting hardened stack..."
pushd "${STACK_DIR}" >/dev/null
docker compose up -d --pull=always --remove-orphans
popd >/dev/null

echo
echo "✅ DONE — All apps are internal; ONLY Caddy (80/443) is exposed."
echo "   Jellyfin (public):    https://${DOMAIN}/jellyfin"
echo "   Protected (BasicAuth user: ${BA_USER}):"
echo "     qBittorrent:        https://${DOMAIN}/qbit"
echo "     Sonarr:             https://${DOMAIN}/sonarr"
echo "     Radarr:             https://${DOMAIN}/radarr"
echo "     Prowlarr:           https://${DOMAIN}/prowlarr"
echo "     Jellyseerr:         https://${DOMAIN}/seerr"
echo
echo "Health checks:"
echo "  docker ps --format 'table {{.Names}}\t{{.Status}}'"
echo "  docker logs caddy --tail=120"
echo "  sudo fail2ban-client status caddy-login"
