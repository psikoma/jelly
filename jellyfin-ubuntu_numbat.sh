#!/usr/bin/env bash
set -Eeuo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Jellyfin + Transmission + Sonarr + Radarr + Prowlarr + Jellyseerr
# Caddy (TLS 1.3, HTTP/3, hardened headers, BasicAuth) + Fail2ban
# Optional No-IP DUC (noip2) w/ systemd
# Ubuntu 24.04.3 (Noble) — supports: --install | --uninstall
# ─────────────────────────────────────────────────────────────────────────────

STACK_DIR="/opt/media-stack"
DATA_ROOT="/srv/media"
CFG="${DATA_ROOT}/config"
CADDY_DIR="${CFG}/caddy"
CADDYFILE="${CADDY_DIR}/Caddyfile"
CADDY_LOG_DIR="/var/log/caddy"
TZ_DEFAULT="Europe/Bucharest"

# ========================= Helpers =========================
usage() {
  cat <<USAGE
Usage:
  sudo bash $0 --install     Install and configure the full media stack
  sudo bash $0 --uninstall   Stop & remove stack, configs, services (safe teardown)

Environment variables (optional to skip prompts):
  DOMAIN                e.g. dexter.gotdns.ch
  EMAIL                 Let's Encrypt email
  BA_USER               BasicAuth username (default: admin)
  BA_PASS               BasicAuth password
  TZ                    Timezone (default: ${TZ_DEFAULT})
  USE_NOIP              Y/N to configure No-IP (default: N)
  NOIP_USERNAME         No-IP username (email) if USE_NOIP=Y
  NOIP_PASSWORD         No-IP password if USE_NOIP=Y
USAGE
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo bash $0)"
    exit 1
  fi
}

detect_user() {
  PRIMARY_USER="$(logname 2>/dev/null || echo "${SUDO_USER:-}")"
  if [[ -z "${PRIMARY_USER:-}" ]]; then
    echo "Could not detect primary user."
    exit 1
  fi
  PUID="$(id -u "$PRIMARY_USER")"
  PGID="$(id -g "$PRIMARY_USER")"
}

confirm() {
  local prompt="${1:-Are you sure?} [y/N]: "
  read -rp "$prompt" ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

# ========================= Install =========================
install_stack() {
  require_root
  detect_user

  # ── Inputs (use env if provided) ──
  DOMAIN="${DOMAIN:-}"
  EMAIL="${EMAIL:-}"
  BA_USER="${BA_USER:-admin}"
  BA_PASS="${BA_PASS:-}"
  TZ="${TZ:-$TZ_DEFAULT}"
  USE_NOIP="${USE_NOIP:-N}"
  if [[ -z "${DOMAIN}" ]]; then read -rp "Domain (e.g. dexter.gotdns.ch): " DOMAIN; fi
  if [[ -z "${EMAIL}"  ]]; then read -rp "Let's Encrypt email: " EMAIL; fi
  if [[ -z "${BA_PASS}" ]]; then read -rsp "BasicAuth password: " BA_PASS; echo; fi
  if [[ -z "${USE_NOIP}" ]]; then read -rp "Configure No-IP? [y/N]: " USE_NOIP; USE_NOIP="${USE_NOIP:-N}"; fi
  if [[ "${USE_NOIP}" =~ ^[Yy]$ ]]; then
    NOIP_USERNAME="${NOIP_USERNAME:-}"; NOIP_PASSWORD="${NOIP_PASSWORD:-}"
    if [[ -z "${NOIP_USERNAME}" ]]; then read -rp "No-IP username (email): " NOIP_USERNAME; fi
    if [[ -z "${NOIP_PASSWORD}" ]]; then read -rsp "No-IP password: " NOIP_PASSWORD; echo; fi
  fi

  # ── Folders/Perms ──
  mkdir -p "$STACK_DIR" "$DATA_ROOT"/{downloads,library/{Movies,TV},config} "$CADDY_LOG_DIR"
  chown -R "$PRIMARY_USER:$PRIMARY_USER" "$STACK_DIR" "$DATA_ROOT"
  chmod -R 775 "$STACK_DIR" "$DATA_ROOT"
  chown root:adm "$CADDY_LOG_DIR" || true
  chmod 750 "$CADDY_LOG_DIR" || true

  # ── System deps ──
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y ca-certificates curl gnupg lsb-release ufw fail2ban wget unzip make gcc expect

  # ── Docker CE (official repo for Noble) ──
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://docs.docker.com/engine/install/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || \
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  usermod -aG docker "$PRIMARY_USER" || true
  # (Docker CE on Ubuntu 24.04 is the recommended path; compose v2 is provided as a plugin). :contentReference[oaicite:5]{index=5}

  # ── Optional: No-IP DUC (noip2) non-interactive ──
  if [[ "${USE_NOIP}" =~ ^[Yy]$ ]]; then
    echo "Installing No-IP DUC (noip2)..."
    cd /tmp
    wget -q https://www.noip.com/client/linux/noip-duc-linux.tar.gz -O noip.tar.gz
    tar xf noip.tar.gz
    cd noip-* || true
    make
    install -m 0755 noip2 /usr/local/bin/noip2
    install -d -m 0755 /usr/local/etc
    export NOIP_USERNAME NOIP_PASSWORD
    cat >/tmp/noip2.expect <<'EXP'
#!/usr/bin/expect -f
set timeout 30
set user $env(NOIP_USERNAME)
set pass $env(NOIP_PASSWORD)
spawn /usr/local/bin/noip2 -C -c /tmp/no-ip2.conf
expect {
  -re "login/email" { send "$user\r"; exp_continue }
  -re "password" { send "$pass\r"; exp_continue }
  -re "update interval" { send "300\r"; exp_continue }
  -re "Do you wish to run something" { send "N\r"; exp_continue }
  -re "New configuration file" { exit 0 }
  eof { exit 0 }
  timeout { exit 1 }
}
EXP
    chmod +x /tmp/noip2.expect
    /usr/bin/timeout 40s /tmp/noip2.expect || true
    pkill -f "/usr/local/bin/noip2 -C" >/dev/null 2>&1 || true
    mv -f /tmp/no-ip2.conf /usr/local/etc/no-ip2.conf 2>/dev/null || true

    cat >/etc/systemd/system/noip2.service <<'SERVICE'
[Unit]
Description=No-IP Dynamic DNS Update Client
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
ExecStart=/usr/local/bin/noip2
PIDFile=/usr/local/etc/no-ip2.pid
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable noip2
    systemctl restart noip2 || true
    # No-IP DUC official download. :contentReference[oaicite:6]{index=6}
  fi

  # ── Compose env ──
  cat > "${STACK_DIR}/.env" <<EOF
TZ=${TZ}
PUID=${PUID}
PGID=${PGID}
DATA_ROOT=${DATA_ROOT}
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${EMAIL}
EOF

  # ── Caddy BasicAuth hash ──
  HASH="$(docker run --rm caddy:2 caddy hash-password --plaintext "$BA_PASS")"
  # Caddy basic_auth directive (modern name). :contentReference[oaicite:7]{index=7}

  # ── docker-compose.yml ──
  cat > "${STACK_DIR}/docker-compose.yml" <<'YML'
x-env: &env
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
    environment: *env
    volumes:
      - ${DATA_ROOT}/config/jellyfin:/config
      - ${DATA_ROOT}/library/TV:/data/tvshows
      - ${DATA_ROOT}/library/Movies:/data/movies
      - ${DATA_ROOT}/downloads:/downloads
    networks: [media-net]
    restart: unless-stopped

  transmission:
    image: lscr.io/linuxserver/transmission:latest
    environment: *env
    volumes:
      - ${DATA_ROOT}/config/transmission:/config
      - ${DATA_ROOT}/downloads:/downloads
    networks: [media-net]
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    environment: *env
    entrypoint: >
      /bin/sh -c '
        mkdir -p /config;
        if [ ! -f /config/config.xml ]; then
          printf "<Config><UrlBase>/sonarr</UrlBase></Config>" > /config/config.xml;
        fi;
        exec /init
      '
    volumes:
      - ${DATA_ROOT}/config/sonarr:/config
      - ${DATA_ROOT}/library/TV:/tv
      - ${DATA_ROOT}/downloads:/downloads
    networks: [media-net]
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    environment: *env
    entrypoint: >
      /bin/sh -c '
        mkdir -p /config;
        if [ ! -f /config/config.xml ]; then
          printf "<Config><UrlBase>/radarr</UrlBase></Config>" > /config/config.xml;
        fi;
        exec /init
      '
    volumes:
      - ${DATA_ROOT}/config/radarr:/config
      - ${DATA_ROOT}/library/Movies:/movies
      - ${DATA_ROOT}/downloads:/downloads
    networks: [media-net]
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    environment: *env
    entrypoint: >
      /bin/sh -c '
        mkdir -p /config;
        if [ ! -f /config/config.xml ]; then
          printf "<Config><UrlBase>/prowlarr</UrlBase></Config>" > /config/config.xml;
        fi;
        exec /init
      '
    volumes:
      - ${DATA_ROOT}/config/prowlarr:/config
    networks: [media-net]
    restart: unless-stopped

  jellyseerr:
    image: fallenbagel/jellyseerr:latest
    environment: *env
    volumes:
      - ${DATA_ROOT}/config/jellyseerr:/app/config
    networks: [media-net]
    restart: unless-stopped

  caddy:
    image: caddy:2
    depends_on:
      - jellyfin
      - transmission
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

  # ── Caddyfile (hardened; subpath via handle_path) ──
  mkdir -p "${CADDY_DIR}"
  cat > "${CADDYFILE}" <<EOF
{
  email ${EMAIL}
  servers {
    protocols h1 h2 h3
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
    output file /var/log/caddy/access.log {
      roll_size 50MB
      roll_keep 5
      roll_keep_for 336h
    }
    format json
  }

  # Public: Jellyfin at /jellyfin
  handle_path /jellyfin/* {
    reverse_proxy jellyfin:8096
  }

  # Protected: Transmission (keeps /transmission/, redirect bare to slash)
  @exactTransmission {
    path /transmission
  }
  redir @exactTransmission /transmission/ permanent
  handle /transmission* {
    basic_auth {
      ${BA_USER} ${HASH}
    }
    reverse_proxy transmission:9091
  }

  # Protected: Sonarr
  handle_path /sonarr/* {
    basic_auth {
      ${BA_USER} ${HASH}
    }
    reverse_proxy sonarr:8989
  }

  # Protected: Radarr
  handle_path /radarr/* {
    basic_auth {
      ${BA_USER} ${HASH}
    }
    reverse_proxy radarr:7878
  }

  # Protected: Prowlarr
  handle_path /prowlarr/* {
    basic_auth {
      ${BA_USER} ${HASH}
    }
    reverse_proxy prowlarr:9696
  }

  # Protected: Jellyseerr (needs X-Forwarded-Prefix)
  handle_path /seerr/* {
    basic_auth {
      ${BA_USER} ${HASH}
    }
    reverse_proxy jellyseerr:5055 {
      header_up X-Forwarded-Prefix /seerr
      header_up X-Forwarded-Proto {scheme}
    }
  }

  # Fallback
  handle {
    respond "Secure media stack online. Try /jellyfin, /transmission, /sonarr, /radarr, /prowlarr, /seerr" 200
  }
}
EOF
  # Caddy handle_path docs. :contentReference[oaicite:8]{index=8}

  # Validate Caddyfile syntax inside container
  docker run --rm -v "${CADDY_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro" -w /etc/caddy caddy:2 caddy validate

  # ── Firewall (per your request: allow ALL incoming) ──
  ufw default allow incoming
  ufw default allow outgoing
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 22/tcp
  ufw --force enable

  # ── Fail2ban for Caddy auth brute-force ──
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
failregex = ^.*"remote_ip":"<HOST>".*"request":\{"method":"POST".*\}.*"status":(401|403).*$
ignoreregex =
FIL
  systemctl enable --now fail2ban
  systemctl restart fail2ban

  # ── Start stack ──
  pushd "$STACK_DIR" >/dev/null
  docker compose up -d --pull=always --remove-orphans
  popd >/dev/null

  echo
  echo "Install complete."
  echo "  Jellyfin (public):      https://${DOMAIN}/jellyfin"
  echo "  Protected (BasicAuth ${BA_USER}):"
  echo "    Transmission:         https://${DOMAIN}/transmission"
  echo "    Sonarr:               https://${DOMAIN}/sonarr"
  echo "    Radarr:               https://${DOMAIN}/radarr"
  echo "    Prowlarr:             https://${DOMAIN}/prowlarr"
  echo "    Jellyseerr:           https://${DOMAIN}/seerr"
}

# ========================= Uninstall =========================
uninstall_stack() {
  require_root

  echo "This will stop containers, remove the stack, delete configs under:"
  echo "  ${STACK_DIR}"
  echo "  ${DATA_ROOT}/config/{jellyfin,transmission,sonarr,radarr,prowlarr,jellyseerr,caddy}"
  echo "  /var/log/caddy"
  echo "It will also remove the noip2 service if present."
  if ! confirm "Proceed with uninstall?"; then
    echo "Aborted."
    exit 0
  fi

  # Stop & remove containers
  if [[ -f "${STACK_DIR}/docker-compose.yml" ]]; then
    (cd "$STACK_DIR" && docker compose down -v) || true
  fi

  # Remove residual named containers (if compose file moved)
  for c in jellyfin transmission sonarr radarr prowlarr jellyseerr caddy; do
    docker stop "$c" >/dev/null 2>&1 || true
    docker rm "$c"   >/dev/null 2>&1 || true
  done

  # Remove Caddy data volumes if they exist (from compose)
  docker volume rm $(docker volume ls -q | grep -E '^media-stack_caddy_(data|config)$') >/dev/null 2>&1 || true

  # Remove files
  rm -rf "${STACK_DIR}" \
         "${DATA_ROOT}/config/jellyfin" \
         "${DATA_ROOT}/config/transmission" \
         "${DATA_ROOT}/config/sonarr" \
         "${DATA_ROOT}/config/radarr" \
         "${DATA_ROOT}/config/prowlarr" \
         "${DATA_ROOT}/config/jellyseerr" \
         "${DATA_ROOT}/config/caddy" || true

  # Optionally remove logs
  if confirm "Also delete /var/log/caddy logs?"; then
    rm -rf /var/log/caddy || true
  fi

  # Remove No-IP service if present
  if systemctl list-unit-files | grep -q '^noip2.service'; then
    systemctl disable --now noip2 || true
    rm -f /etc/systemd/system/noip2.service
    systemctl daemon-reload
    rm -f /usr/local/etc/no-ip2.conf /usr/local/bin/noip2 || true
  fi

  echo "Uninstall completed."
}

# ========================= Entry =========================
case "${1:-}" in
  --install)
    install_stack
    ;;
  --uninstall)
    uninstall_stack
    ;;
  *)
    usage
    exit 1
    ;;
esac
