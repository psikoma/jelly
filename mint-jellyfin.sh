#!/usr/bin/env bash
# install-interactive.sh — Interactive Production Jellyfin Stack Installer
# for Linux Mint 22.2 / Ubuntu 24.04
# Components: Jellyfin + qBittorrent + Sonarr + Radarr + Prowlarr + Seerr + Caddy + Watchtower
# Optional: No-IP ddclient for dynamic DNS

set -Eeuo pipefail

### ───── Helper Functions ────────────────────────────────────────────────
ask() {
  local prompt="$1" default="$2" var
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " var
    echo "${var:-$default}"
  else
    read -rp "$prompt: " var
    echo "$var"
  fi
}

ask_secret() {
  local prompt="$1" var
  read -rsp "$prompt: " var
  echo
  echo "$var"
}

yes_no() {
  local prompt="$1" default="$2" choice
  while true; do
    read -rp "$prompt ($([[ "$default" == "y" ]] && echo Y/n || echo y/N)): " choice
    choice="${choice:-$default}"
    case "$choice" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

### ───── Interactive Prompts ─────────────────────────────────────────────
echo "=== 🧰 Jellyfin Media Stack Installer ==="
echo "This will set up Jellyfin, qBittorrent, Sonarr, Radarr, Prowlarr, Seerr, Caddy & Watchtower."
echo "Tested on Linux Mint 22.2 / Ubuntu 24.04 (noble)."
echo

STACK_DIR=$(ask "Install directory (stack)" "/opt/jellyfin-stack")
DATA_ROOT=$(ask "Media/data directory" "/srv/media")
TZ=$(ask "Timezone" "Europe/Bucharest")
DOMAIN=$(ask "Your domain (for HTTPS)" "dexter.gotdns.ch")
LETSENCRYPT_EMAIL=$(ask "Email for Let's Encrypt" "you@example.com")

if yes_no "Use subdomains instead of path routing? (jellyfin.DOMAIN vs DOMAIN/jellyfin)" "n"; then
  USE_SUBDOMAINS="true"
else
  USE_SUBDOMAINS="false"
fi

if yes_no "Do you want to configure No-IP dynamic DNS?" "n"; then
  NOIP_USERNAME=$(ask "No-IP username" "")
  NOIP_PASSWORD=$(ask_secret "No-IP password")
  NOIP_HOSTNAME=$(ask "No-IP hostname" "$DOMAIN")
else
  NOIP_USERNAME=""
  NOIP_PASSWORD=""
  NOIP_HOSTNAME="$DOMAIN"
fi

echo
echo "╭───────────────────────────────╮"
echo "│ Summary of your selections:   │"
echo "├───────────────────────────────┤"
echo "│ Stack Dir:      $STACK_DIR"
echo "│ Data Root:      $DATA_ROOT"
echo "│ Timezone:       $TZ"
echo "│ Domain:         $DOMAIN"
echo "│ Email:          $LETSENCRYPT_EMAIL"
echo "│ Routing:        $([[ $USE_SUBDOMAINS == true ]] && echo 'Subdomains' || echo 'Path routing')"
if [[ -n "$NOIP_USERNAME" ]]; then
  echo "│ No-IP:          enabled ($NOIP_HOSTNAME)"
else
  echo "│ No-IP:          disabled"
fi
echo "╰───────────────────────────────╯"
echo

if ! yes_no "Proceed with installation?" "y"; then
  echo "❌ Installation cancelled."
  exit 0
fi

### ───── Base Setup ─────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive

echo ">>> Updating system and installing dependencies..."
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban make gcc tar wget software-properties-common

### ───── Docker Engine Install ─────────────────────────────────────────────
echo ">>> Installing Docker Engine..."
grep -rl "download.docker.com" /etc/apt/sources.list* /etc/apt/sources.list.d 2>/dev/null | xargs -r rm -f || true
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

PRIMARY_USER="$(logname 2>/dev/null || true)"
if [[ -n "$PRIMARY_USER" ]]; then
  usermod -aG docker "$PRIMARY_USER" || true
  PUID="$(id -u "$PRIMARY_USER")"
  PGID="$(id -g "$PRIMARY_USER")"
else
  PUID=1000
  PGID=1000
fi

### ───── Optional No-IP ─────────────────────────────────────────────
if [[ -n "$NOIP_USERNAME" && -n "$NOIP_PASSWORD" ]]; then
  echo ">>> Installing ddclient for No-IP..."
  apt-get install -y ddclient
  cat >/etc/ddclient.conf <<CFG
protocol=dyndns2
use=web, web=checkip.amazonaws.com/
server=dynupdate.no-ip.com
ssl=yes
login=${NOIP_USERNAME}
password='${NOIP_PASSWORD}'
${NOIP_HOSTNAME}
CFG
  chmod 600 /etc/ddclient.conf
  sed -i 's/^#\?run_daemon=.*/run_daemon="true"/' /etc/default/ddclient
  sed -i 's/^#\?daemon_interval=.*/daemon_interval="300"/' /etc/default/ddclient
  systemctl enable --now ddclient
fi

### ───── Directory Setup ─────────────────────────────────────────────
mkdir -p "$STACK_DIR"
mkdir -p "$DATA_ROOT"/{downloads,library/{Movies,TV},config/{jellyfin,qbit,sonarr,radarr,prowlarr,seerr,jellyseerr,caddy}}
chmod -R 755 "$DATA_ROOT"

### ───── .env for Compose ─────────────────────────────────────────────
cat > "$STACK_DIR/.env" <<EOF
TZ=${TZ}
PUID=${PUID}
PGID=${PGID}
DATA_ROOT=${DATA_ROOT}
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
USE_SUBDOMAINS=${USE_SUBDOMAINS}
EOF

### ───── docker-compose.yml ─────────────────────────────────────────────
cat > "$STACK_DIR/docker-compose.yml" <<'YML'
x-env: &core_env
  TZ: ${TZ}
  PUID: ${PUID}
  PGID: ${PGID}

networks:
  media-net:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    environment:
      <<: *core_env
      JELLYFIN_PublishedServerUrl: ${DOMAIN:+https://${DOMAIN}}
    volumes:
      - ${DATA_ROOT}/config/jellyfin:/config
      - ${DATA_ROOT}/library:/media
      - ${DATA_ROOT}/downloads:/downloads
    ports:
      - "8096:8096"
    networks: [media-net]
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      <<: *core_env
      WEBUI_PORT: 8080
    volumes:
      - ${DATA_ROOT}/config/qbit:/config
      - ${DATA_ROOT}/downloads:/downloads
    ports:
      - "8080:8080"
      - "6881:6881"
      - "6881:6881/udp"
    networks: [media-net]
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment: *core_env
    volumes:
      - ${DATA_ROOT}/config/sonarr:/config
      - ${DATA_ROOT}/library/TV:/tv
      - ${DATA_ROOT}/downloads:/downloads
    ports:
      - "8989:8989"
    networks: [media-net]
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment: *core_env
    volumes:
      - ${DATA_ROOT}/config/radarr:/config
      - ${DATA_ROOT}/library/Movies:/movies
      - ${DATA_ROOT}/downloads:/downloads
    ports:
      - "7878:7878"
    networks: [media-net]
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment: *core_env
    volumes:
      - ${DATA_ROOT}/config/prowlarr:/config
    ports:
      - "9696:9696"
    networks: [media-net]
    restart: unless-stopped

  seerr-proxy:
    image: busybox
    command: sh -c "sleep 3600"
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
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DOMAIN=${DOMAIN}
      - LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
      - USE_SUBDOMAINS=${USE_SUBDOMAINS}
    volumes:
      - ${DATA_ROOT}/config/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [media-net]
    restart: unless-stopped

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    command: --cleanup --schedule "0 0 4 * * *"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [media-net]
    restart: unless-stopped
YML

### ───── Seerr or Jellyseerr ─────────────────────────────────────────────
echo ">>> Selecting Seerr image..."
if docker pull ghcr.io/seerr-team/seerr:latest >/dev/null 2>&1; then
  cat > "$STACK_DIR/docker-compose.override.yml" <<'YML'
services:
  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: seerr
    environment:
      - PORT=5055
    ports:
      - "5055:5055"
    volumes:
      - ${DATA_ROOT}/config/seerr:/app/config
    networks: [media-net]
    restart: unless-stopped
  seerr-proxy:
    image: ghcr.io/seerr-team/seerr:latest
YML
else
  echo ">>> Falling back to Jellyseerr..."
  docker pull fallenbagel/jellyseerr:latest >/dev/null 2>&1 || true
  cat > "$STACK_DIR/docker-compose.override.yml" <<'YML'
services:
  seerr:
    image: fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    ports:
      - "5055:5055"
    volumes:
      - ${DATA_ROOT}/config/jellyseerr:/app/config
    networks: [media-net]
    restart: unless-stopped
  seerr-proxy:
    image: fallenbagel/jellyseerr:latest
YML
fi

### ───── Caddyfile ─────────────────────────────────────────────
mkdir -p "$DATA_ROOT/config/caddy"
if [[ "$USE_SUBDOMAINS" == "true" ]]; then
  cat > "$DATA_ROOT/config/caddy/Caddyfile" <<EOF
{
  email $LETSENCRYPT_EMAIL
}
jellyfin.$DOMAIN {
  reverse_proxy jellyfin:8096
}
seerr.$DOMAIN {
  reverse_proxy seerr:5055
}
qbit.$DOMAIN {
  reverse_proxy qbittorrent:8080
}
sonarr.$DOMAIN {
  reverse_proxy sonarr:8989
}
radarr.$DOMAIN {
  reverse_proxy radarr:7878
}
prowlarr.$DOMAIN {
  reverse_proxy prowlarr:9696
}
EOF
else
  cat > "$DATA_ROOT/config/caddy/Caddyfile" <<EOF
{
  email $LETSENCRYPT_EMAIL
}
$DOMAIN {
  handle_path /jellyfin/* {
    reverse_proxy jellyfin:8096
  }
  handle_path /seerr/* {
    reverse_proxy seerr:5055
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
  handle_path /prowlarr/* {
    reverse_proxy prowlarr:9696
  }
}
EOF
fi

### ───── Firewall + Fail2ban ─────────────────────────────────────────────
ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw --force enable || true

if [[ ! -f /etc/fail2ban/jail.local ]]; then
  cat >/etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = systemd
maxretry = 5
EOF
  systemctl enable --now fail2ban
fi

### ───── Launch Stack ─────────────────────────────────────────────
pushd "$STACK_DIR" >/dev/null
docker compose up -d --pull=always --remove-orphans
popd >/dev/null

LOCAL_IP="$(hostname -I | awk '{print $1}')"

echo
echo "✅ Installation complete!"
echo "────────────────────────────────────────────"
echo "Public URLs (after DNS & port forwarding):"
if [[ "$USE_SUBDOMAINS" == "true" ]]; then
  echo "  Jellyfin:    https://jellyfin.$DOMAIN"
  echo "  Seerr:       https://seerr.$DOMAIN"
  echo "  qBittorrent: https://qbit.$DOMAIN"
  echo "  Sonarr:      https://sonarr.$DOMAIN"
  echo "  Radarr:      https://radarr.$DOMAIN"
  echo "  Prowlarr:    https://prowlarr.$DOMAIN"
else
  echo "  Jellyfin:    https://$DOMAIN/jellyfin"
  echo "  Seerr:       https://$DOMAIN/seerr"
  echo "  qBittorrent: https://$DOMAIN/qbit"
  echo "  Sonarr:      https://$DOMAIN/sonarr"
  echo "  Radarr:      https://$DOMAIN/radarr"
  echo "  Prowlarr:    https://$DOMAIN/prowlarr"
fi
echo
echo "Local URLs (LAN):"
echo "  Jellyfin:    http://$LOCAL_IP:8096"
echo "  qBittorrent: http://$LOCAL_IP:8080"
echo "  Sonarr:      http://$LOCAL_IP:8989"
echo "  Radarr:      http://$LOCAL_IP:7878"
echo "  Prowlarr:    http://$LOCAL_IP:9696"
echo "  Seerr:       http://$LOCAL_IP:5055"
echo
echo "💡 Tips:"
echo " - Forward TCP 80/443 on your router to this machine to enable HTTPS."
echo " - If using path routing, set Jellyfin Base URL to /jellyfin in its Dashboard."
echo " - Connect Seerr → Jellyfin, Sonarr, Radarr → qBittorrent internally."
echo " - Watchtower will keep your stack auto-updated."
