#!/usr/bin/env bash
set -Eeuo pipefail

# ──────────────────────────────────────────────────────────────
# Native Media Stack (no Docker) for Ubuntu 24.04.3
# Jellyfin + qBittorrent (nox) + Sonarr + Radarr + Prowlarr + Jellyseerr
# Caddy (TLS/HTTP3, headers, BasicAuth) + No-IP DUC (noip2) + UFW/Fail2ban
# ──────────────────────────────────────────────────────────────

STACK_ROOT="/opt/media-stack"
DATA_ROOT="/srv/media"
CFG_ROOT="${DATA_ROOT}/config"
CADDY_LOG="/var/log/caddy"
DEFAULT_DOMAIN="dexter.gotdns.ch"
DEFAULT_TZ="Europe/Bucharest"

# Canonical trailing-slash subpaths
BASE_JELLYFIN="/jellyfin/"
BASE_QBIT="/qbit/"
BASE_SONARR="/sonarr/"
BASE_RADARR="/radarr/"
BASE_PROWLARR="/prowlarr/"
BASE_SEERR="/seerr/"

MODE="${1:-}"
[[ "$MODE" == "--install" || "$MODE" == "--uninstall" ]] || {
  echo "Usage: sudo bash $0 --install | --uninstall"
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  echo "❌ Run as root: sudo bash $0 --install|--uninstall"
  exit 1
fi

PRIMARY_USER="$(logname 2>/dev/null || echo "${SUDO_USER:-}")"
PUID="$(id -u "$PRIMARY_USER")"
PGID="$(id -g "$PRIMARY_USER")"

mkdir -p "$STACK_ROOT" "$DATA_ROOT"/{downloads,library/Movies,library/TV,config} "$CADDY_LOG"
chown -R "$PRIMARY_USER:$PRIMARY_USER" "$STACK_ROOT" "$DATA_ROOT"
chmod -R 775 "$DATA_ROOT"

# ──────────────────────────────────────────────────────────────
# UNINSTALL MODE
# ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "--uninstall" ]]; then
  systemctl stop caddy jellyfin qbittorrent sonarr radarr prowlarr jellyseerr noip2 2>/dev/null || true
  systemctl disable caddy jellyfin qbittorrent sonarr radarr prowlarr jellyseerr noip2 2>/dev/null || true
  rm -f /etc/systemd/system/{qbittorrent.service,sonarr.service,radarr.service,prowlarr.service,jellyseerr.service,noip2.service}
  systemctl daemon-reload
  rm -rf /opt/{sonarr,radarr,prowlarr,jellyseerr}
  read -rp "Delete ${DATA_ROOT}? (y/N): " ans
  [[ $ans =~ ^[Yy]$ ]] && rm -rf "${DATA_ROOT}"
  rm -f /usr/local/bin/noip2 /usr/local/etc/no-ip2.conf
  echo "✅ Uninstall complete."
  exit 0
fi

# ──────────────────────────────────────────────────────────────
# INSTALL MODE
# ──────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
read -rp "Domain for HTTPS [${DOMAIN}]: " _d || true; DOMAIN="${_d:-$DOMAIN}"

BA_USER="admin"
read -rp "BasicAuth username [${BA_USER}]: " _u || true; BA_USER="${_u:-$BA_USER}"
read -rsp "BasicAuth password: " BA_PASS; echo

read -rp "Configure No-IP DUC (noip2)? [Y/n]: " USE_NOIP
USE_NOIP="${USE_NOIP:-Y}"
if [[ "$USE_NOIP" =~ ^[Yy]$ ]]; then
  read -rp "No-IP username (email): " NOIP_USERNAME
  read -rsp "No-IP password: " NOIP_PASSWORD; echo
fi

# Base packages
apt-get update -y
apt-get install -y curl wget jq tar unzip ca-certificates gnupg lsb-release ufw fail2ban expect debian-keyring debian-archive-keyring

# ── Jellyfin
bash -c 'curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash'
apt-get install -y jellyfin
cat >/etc/jellyfin/system/network.xml <<NET
<NetworkConfiguration>
  <BaseUrl>${BASE_JELLYFIN%/}</BaseUrl>
  <PublicHttpsPort>443</PublicHttpsPort>
</NetworkConfiguration>
NET
chown -R jellyfin:jellyfin /etc/jellyfin
systemctl enable --now jellyfin

# ── qBittorrent
apt-get install -y qbittorrent-nox
useradd -r -s /usr/sbin/nologin -d /var/lib/qbittorrent qbittorrent 2>/dev/null || true
install -d -o qbittorrent -g qbittorrent /var/lib/qbittorrent/.config/qBittorrent
cat >/var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf <<QBIT
[Preferences]
WebUI\Address=*
WebUI\Enabled=true
WebUI\Port=8080
WebUI\Username=admin
WebUI\Password_PBKDF2=@ByteArray(PBKDF2$sha256$100000$frTE5dWZo2B5Phjj7ZblDQ==$WE+pssfy9sF36AJdj1k1Z6ioBS2UpCsjNeAkni5aR3E=)
WebUI\HostHeaderValidation=false
WebUI\TrustedReverseProxies=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.1/32
WebUI\MaxAuthenticationFailCount=50
QBIT
chown -R qbittorrent:qbittorrent /var/lib/qbittorrent

cat >/etc/systemd/system/qbittorrent.service <<'UNIT'
[Unit]
Description=qBittorrent-nox
After=network-online.target
Wants=network-online.target

[Service]
User=qbittorrent
Group=qbittorrent
Type=simple
Environment=HOME=/var/lib/qbittorrent
ExecStart=/usr/bin/qbittorrent-nox --webui-port=8080 --profile=/var/lib/qbittorrent
Restart=on-failure
RestartSec=5
UMask=002

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now qbittorrent

# ── Sonarr / Radarr / Prowlarr / Jellyseerr
install_arr() {
  local name="$1" repo="$2" port="$3" urlbase="${4%/}"
  local dest="/opt/$name"
  mkdir -p "$dest"
  local url
  url=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
    jq -r '.assets[] | select(.name|test("linux.*x64.*\\.tar\\.gz$")) | .browser_download_url' | head -n1)
  tmp=$(mktemp -d); curl -fsSL "$url" -o "$tmp/$name.tgz"; tar -xzf "$tmp/$name.tgz" -C "$dest" --strip-components=1
  install -d -o "$PRIMARY_USER" -g "$PRIMARY_USER" "$CFG_ROOT/$name"
  if [[ "$name" != "jellyseerr" ]]; then
    cat >"$CFG_ROOT/$name/config.xml" <<XML
<Config>
  <UrlBase>${urlbase}</UrlBase>
</Config>
XML
  fi
  local bin
  case "$name" in
    sonarr) bin="Sonarr";;
    radarr) bin="Radarr";;
    prowlarr) bin="Prowlarr";;
    jellyseerr) bin="jellyseerr";;
  esac
  cat >/etc/systemd/system/$name.service <<EOF
[Unit]
Description=${name^} Service
After=network-online.target

[Service]
User=$PRIMARY_USER
Group=$PRIMARY_USER
Environment=APPDATA=$CFG_ROOT/$name
WorkingDirectory=$dest
ExecStart=$dest/$bin -nobrowser
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now $name
}

install_arr sonarr Sonarr/Sonarr 8989 "$BASE_SONARR"
install_arr radarr Radarr/Radarr 7878 "$BASE_RADARR"
install_arr prowlarr Prowlarr/Prowlarr 9696 "$BASE_PROWLARR"
install_arr jellyseerr Fallenbagel/jellyseerr 5055 "$BASE_SEERR"

# ── Caddy
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy
HASH="$(caddy hash-password --plaintext "$BA_PASS")"
CADDYFILE="$CFG_ROOT/caddy/Caddyfile"
mkdir -p "$CFG_ROOT/caddy"

SITE="https://${DOMAIN}"
cat >"$CADDYFILE" <<EOF
{
  email admin@${DOMAIN}
  servers {
    protocols h1 h2 h3
  }
}

${SITE} {
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
    output file ${CADDY_LOG}/access.log
    format json
  }

  # Jellyfin
  @jfin { path ${BASE_JELLYFIN%/} }
  redir @jfin ${BASE_JELLYFIN} permanent
  handle_path ${BASE_JELLYFIN}* {
    reverse_proxy 127.0.0.1:8096
  }

  # qBittorrent
  @qbit { path ${BASE_QBIT%/} }
  redir @qbit ${BASE_QBIT} permanent
  handle_path ${BASE_QBIT}* {
    basicauth { ${BA_USER} ${HASH} }
    reverse_proxy 127.0.0.1:8080
  }

  # Sonarr
  @sonarr { path ${BASE_SONARR%/} }
  redir @sonarr ${BASE_SONARR} permanent
  handle_path ${BASE_SONARR}* {
    basicauth { ${BA_USER} ${HASH} }
    reverse_proxy 127.0.0.1:8989
  }

  # Radarr
  @radarr { path ${BASE_RADARR%/} }
  redir @radarr ${BASE_RADARR} permanent
  handle_path ${BASE_RADARR}* {
    basicauth { ${BA_USER} ${HASH} }
    reverse_proxy 127.0.0.1:7878
  }

  # Prowlarr
  @prowlarr { path ${BASE_PROWLARR%/} }
  redir @prowlarr ${BASE_PROWLARR} permanent
  handle_path ${BASE_PROWLARR}* {
    basicauth { ${BA_USER} ${HASH} }
    reverse_proxy 127.0.0.1:9696
  }

  # Jellyseerr
  @seerr { path ${BASE_SEERR%/} }
  redir @seerr ${BASE_SEERR} permanent
  handle_path ${BASE_SEERR}* {
    basicauth { ${BA_USER} ${HASH} }
    reverse_proxy 127.0.0.1:5055 {
      header_up X-Forwarded-Prefix ${BASE_SEERR%/}
      header_up X-Forwarded-Proto {scheme}
    }
  }

  handle {
    respond "Secure media stack online. Try ${BASE_JELLYFIN} ${BASE_QBIT} ${BASE_SONARR} ${BASE_RADARR} ${BASE_PROWLARR} ${BASE_SEERR}" 200
  }
}
EOF
ln -sf "$CADDYFILE" /etc/caddy/Caddyfile
systemctl enable --now caddy

# ── No-IP DUC
if [[ "$USE_NOIP" =~ ^[Yy]$ ]]; then
  cd /tmp
  wget -q https://www.noip.com/client/linux/noip-duc-linux.tar.gz -O noip.tar.gz
  tar xf noip.tar.gz && cd noip-*
  make
  install -m 0755 noip2 /usr/local/bin/noip2
  install -d -m 0755 /usr/local/etc

  export NOIP_USERNAME NOIP_PASSWORD
  cat >/tmp/noip2.expect <<'EXP'
#!/usr/bin/expect -f
set timeout 40
set user $env(NOIP_USERNAME)
set pass $env(NOIP_PASSWORD)
spawn /usr/local/bin/noip2 -C -c /tmp/no-ip2.conf
expect {
  -re "login/email" { send "$user\r"; exp_continue }
  -re "password" { send "$pass\r"; exp_continue }
  -re "update interval" { send "300\r"; exp_continue }
  -re "Do you wish to run something" { send "N\r"; exp_continue }
  -re "New configuration file" { exit 0 }
  timeout { exit 0 }
  eof { exit 0 }
}
EXP
  chmod +x /tmp/noip2.expect
  timeout 45s /tmp/noip2.expect || true
  mv -f /tmp/no-ip2.conf /usr/local/etc/no-ip2.conf
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
  systemctl enable --now noip2
fi

# ── Firewall + Fail2ban
ufw default allow incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

mkdir -p /etc/fail2ban/{jail.d,filter.d}
cat >/etc/fail2ban/jail.d/caddy-login.conf <<'JAIL'
[caddy-login]
enabled = true
filter = caddy-login
logpath = /var/log/caddy/access.log
maxretry = 5
findtime = 600
bantime = 3600
JAIL
cat >/etc/fail2ban/filter.d/caddy-login.conf <<'FIL'
[Definition]
failregex = ^<HOST> .* "POST .*" (401|403) .*
ignoreregex =
FIL
systemctl enable --now fail2ban

# ── Output
LOCAL_IP="$(hostname -I | awk '{print $1}')"
echo
echo "✅ Installation complete"
echo "🌍 Public:  https://${DOMAIN}${BASE_JELLYFIN}"
echo "🔐 Auth'd: https://${DOMAIN}${BASE_QBIT} (admin/adminadmin)"
echo "           https://${DOMAIN}${BASE_SONARR}"
echo "           https://${DOMAIN}${BASE_RADARR}"
echo "           https://${DOMAIN}${BASE_PROWLARR}"
echo "           https://${DOMAIN}${BASE_SEERR}"
echo "💻 Local:   https://${LOCAL_IP}${BASE_JELLYFIN}"
