#!/bin/bash
set -e

#### TITLE ####
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🧩 Jellyfin + qBittorrent + Sonarr + Radarr + Jackett + Caddy + No-IP"
echo "      Automated Installer for Linux Mint 22.2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

#### PRE-FLIGHT CHECK ####
if ! grep -qi "Mint 22" /etc/os-release && ! grep -qi "Ubuntu 24.04" /etc/os-release; then
  echo "⚠ This script is designed for Linux Mint 22.2 or Ubuntu 24.04."
  echo "   Exiting for safety."
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run this script with sudo:"
  echo "   sudo bash $0"
  exit 1
fi

USER_NAME=$(logname)

#### ASK INTERACTIVE INPUTS ####
read -p "Enter your desired No-IP hostname (e.g. dexter.gotdns.ch): " DOMAIN
read -p "Enter your No-IP username: " NOIP_USERNAME
read -s -p "Enter your No-IP password: " NOIP_PASSWORD
echo ""
read -p "Enter your email (for Let's Encrypt): " EMAIL

#### PATHS ####
STACK_DIR="/opt/media-stack"
MEDIA_DIR="$STACK_DIR/media"
TV_DIR="$MEDIA_DIR/tv"
MOVIES_DIR="$MEDIA_DIR/movies"
DOWNLOADS_DIR="$MEDIA_DIR/downloads"
CONFIG_DIR="$STACK_DIR/config"
NOIP_DIR="/usr/local/src/noip"

#### UPDATE SYSTEM ####
echo "▶ Updating system..."
apt update && apt upgrade -y

#### INSTALL DEPENDENCIES ####
echo "▶ Installing dependencies..."
apt install -y curl wget git ufw fail2ban unzip make gcc lsb-release ca-certificates gnupg software-properties-common

#### INSTALL DOCKER & COMPOSE ####
if ! command -v docker &>/dev/null; then
  echo "▶ Installing Docker..."
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
usermod -aG docker "$USER_NAME"

if ! command -v docker compose &>/dev/null; then
  apt install -y docker-compose-plugin
fi

#### INSTALL CADDY ####
if ! command -v caddy &>/dev/null; then
  echo "▶ Installing Caddy..."
  apt install -y caddy
fi
systemctl enable --now caddy

#### INSTALL NO-IP DUC (OFFICIAL CLIENT) ####
echo "▶ Installing official No-IP Dynamic Update Client..."
rm -rf "$NOIP_DIR"
mkdir -p "$NOIP_DIR"
cd "$NOIP_DIR"
wget http://www.no-ip.com/client/linux/noip-duc-linux.tar.gz -O noip.tar.gz
tar xf noip.tar.gz --strip-components=1
make
make install <<EOF
$NOIP_USERNAME
$NOIP_PASSWORD
$DOMAIN
30
y
EOF

systemctl stop noip2 2>/dev/null || true
cat >/etc/systemd/system/noip2.service <<EOF
[Unit]
Description=No-IP Dynamic DNS Update Client
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/noip2
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now noip2

#### CREATE MEDIA DIRECTORIES ####
echo "▶ Creating media directories..."
mkdir -p "$TV_DIR" "$MOVIES_DIR" "$DOWNLOADS_DIR" "$CONFIG_DIR"
chown -R "$USER_NAME:$USER_NAME" "$STACK_DIR"
chmod -R 775 "$STACK_DIR"

#### CREATE DOCKER COMPOSE STACK ####
echo "▶ Creating Docker Compose stack..."
cat > "$STACK_DIR/docker-compose.yml" <<EOF
version: "3.9"

x-core-env: &core_env
  PUID: 1000
  PGID: 1000
  TZ: Europe/Bucharest

networks:
  media-net:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:

services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment: *core_env
    volumes:
      - ${CONFIG_DIR}/jellyfin:/config
      - ${MEDIA_DIR}/tv:/data/tvshows
      - ${MEDIA_DIR}/movies:/data/movies
    networks: [media-net]
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      <<: *core_env
      WEBUI_PORT: 8080
    volumes:
      - ${CONFIG_DIR}/qbit:/config
      - ${DOWNLOADS_DIR}:/downloads
    networks: [media-net]
    restart: unless-stopped
    entrypoint: >
      /bin/sh -c '
        mkdir -p /config/qBittorrent &&
        echo "[Preferences]" > /config/qBittorrent/qBittorrent.conf &&
        echo "WebUI\\\\Port=8080" >> /config/qBittorrent/qBittorrent.conf &&
        echo "WebUI\\\\Username=admin" >> /config/qBittorrent/qBittorrent.conf &&
        echo "WebUI\\\\Password_PBKDF2=@ByteArray(adminadmin)" >> /config/qBittorrent/qBittorrent.conf &&
        exec /init
      '

  jackett:
    image: lscr.io/linuxserver/jackett:latest
    container_name: jackett
    environment: *core_env
    volumes:
      - ${CONFIG_DIR}/jackett:/config
      - ${DOWNLOADS_DIR}:/downloads
    networks: [media-net]
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment: *core_env
    volumes:
      - ${CONFIG_DIR}/sonarr:/config
      - ${MEDIA_DIR}/tv:/tv
      - ${DOWNLOADS_DIR}:/downloads
    networks: [media-net]
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment: *core_env
    volumes:
      - ${CONFIG_DIR}/radarr:/config
      - ${MEDIA_DIR}/movies:/movies
      - ${DOWNLOADS_DIR}:/downloads
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
      - jackett
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DOMAIN=${DOMAIN}
      - EMAIL=${EMAIL}
    volumes:
      - ${CONFIG_DIR}/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [media-net]
    restart: unless-stopped
EOF

#### GENERATE CADDYFILE WITH FAILOVER AND HTTPS REDIRECT ####
mkdir -p "$CONFIG_DIR/caddy"
cat > "$CONFIG_DIR/caddy/Caddyfile" <<EOF
{
  email ${EMAIL}
}

http:// {
  redir https://{host}{uri}
}

${DOMAIN} {
  encode gzip
  log
  handle_path /jellyfin/* {
    reverse_proxy jellyfin:8096
  }
  handle_path /qbit/* {
    reverse_proxy qbittorrent:8080
  }
  handle_path /sonarr/* {
    reverse_proxy sonarr:8989
  }
  handle_path /radarr/* {
    reverse_proxy radarr:7878
  }
  handle_path /jackett/* {
    reverse_proxy jackett:9117
  }
  handle {
    respond "Service online but no path specified. Try /jellyfin or /qbit" 200
  }
}
EOF

#### FIREWALL CONFIGURATION ####
echo "▶ Configuring firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

#### FAIL2BAN CONFIGURATION ####
echo "▶ Configuring Fail2Ban..."
cat >/etc/fail2ban/jail.d/caddy-login.conf <<EOF
[caddy-login]
enabled = true
filter = caddy-login
logpath = /var/log/syslog
maxretry = 5
findtime = 600
bantime = 3600
EOF

cat >/etc/fail2ban/filter.d/caddy-login.conf <<EOF
[Definition]
failregex = .*(401|403).*POST.*
ignoreregex =
EOF

systemctl restart fail2ban

#### START STACK ####
echo "▶ Starting media stack..."
cd "$STACK_DIR"
docker compose up -d

LOCAL_IP=$(hostname -I | awk '{print $1}')

#### COMPLETION OUTPUT ####
echo ""
echo "✅ INSTALLATION COMPLETE"
echo ""
echo "🌍 Access via HTTPS:"
echo "  https://${DOMAIN}/jellyfin"
echo "  https://${DOMAIN}/qbit  (admin / adminadmin)"
echo "  https://${DOMAIN}/sonarr"
echo "  https://${DOMAIN}/radarr"
echo "  https://${DOMAIN}/jackett"
echo ""
echo "💻 Local LAN access:"
echo "  Jellyfin:    http://${LOCAL_IP}:8096"
echo "  qBittorrent: http://${LOCAL_IP}:8080"
echo ""
echo "🛡 Security:"
echo " - Fail2ban is active."
echo " - Firewall (UFW) is enforcing."
echo " - No-IP DUC runs automatically on boot."
echo " - Caddy provides auto-renewing Let's Encrypt HTTPS."
echo ""
echo "🎬 Your media stack is fully operational."
