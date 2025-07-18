#!/bin/bash

set -e

#### CONFIGURATION ####
MEDIA_DIR="/media"
TV_DIR="$MEDIA_DIR/tv"
MOVIES_DIR="$MEDIA_DIR/movies"
DOWNLOADS_DIR="$MEDIA_DIR/downloads"
JELLYFIN_GROUP="media"
USER="$(whoami)"
#######################

echo "▶ Updating system..."
sudo apt update && sudo apt upgrade -y

echo "▶ Installing required dependencies..."
sudo apt install -y curl wget gnupg ca-certificates software-properties-common unzip sqlite3 libmono-cil-dev mediainfo apt-transport-https

echo "▶ Creating media directories..."
sudo mkdir -p "$TV_DIR" "$MOVIES_DIR" "$DOWNLOADS_DIR"
sudo chown -R "$USER:$JELLYFIN_GROUP" "$MEDIA_DIR"
sudo chmod -R 775 "$MEDIA_DIR"

echo "▶ Creating media group and assigning permissions..."
sudo groupadd -f $JELLYFIN_GROUP
sudo usermod -aG $JELLYFIN_GROUP $USER

echo "▶ Installing Jellyfin..."
wget -O - https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/jellyfin-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/jellyfin-archive-keyring.gpg] https://repo.jellyfin.org/ubuntu focal main" | sudo tee /etc/apt/sources.list.d/jellyfin.list
sudo apt update
sudo apt install -y jellyfin

echo "▶ Adding Jellyfin to media group..."
sudo usermod -aG $JELLYFIN_GROUP jellyfin

echo "▶ Installing qBittorrent-nox..."
sudo apt install -y qbittorrent-nox
sudo usermod -aG $JELLYFIN_GROUP qbittorrent

echo "▶ Creating qbittorrent autostart systemd service..."
sudo bash -c 'cat >/etc/systemd/system/qbittorrent-nox.service' <<EOF
[Unit]
Description=qBittorrent-nox
After=network.target

[Service]
User=$USER
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now qbittorrent-nox.service

echo "▶ Installing Jackett..."
wget https://github.com/Jackett/Jackett/releases/latest/download/Jackett.Binaries.LinuxAMDx64.tar.gz
mkdir -p ~/apps/jackett
tar -xzf Jackett.Binaries.LinuxAMDx64.tar.gz -C ~/apps/jackett --strip-components=1
rm Jackett.Binaries.LinuxAMDx64.tar.gz
bash ~/apps/jackett/install_service_systemd.sh

echo "▶ Installing Sonarr..."
sudo curl -fsSL https://apt.sonarr.tv/keys/sonarr.asc | gpg --dearmor -o /usr/share/keyrings/sonarr.gpg
echo "deb [signed-by=/usr/share/keyrings/sonarr.gpg] https://apt.sonarr.tv/debian master main" | sudo tee /etc/apt/sources.list.d/sonarr.list
sudo apt update
sudo apt install -y sonarr
sudo systemctl enable --now sonarr

echo "▶ Installing Radarr..."
wget https://github.com/Radarr/Radarr/releases/latest/download/Radarr.master.tar.gz
sudo mkdir -p /opt/radarr
sudo tar -xvzf Radarr.master.tar.gz -C /opt/radarr --strip-components=1
sudo rm Radarr.master.tar.gz

sudo bash -c 'cat >/etc/systemd/system/radarr.service' <<EOF
[Unit]
Description=Radarr
After=network.target

[Service]
User=$USER
Group=$JELLYFIN_GROUP
Type=simple
ExecStart=/opt/radarr/Radarr -nobrowser
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl enable --now radarr.service

echo "▶ Fixing folder ownership and permissions..."
sudo chown -R $USER:$JELLYFIN_GROUP "$MEDIA_DIR"
sudo chmod -R 775 "$MEDIA_DIR"

echo "✅ INSTALLATION COMPLETE"

echo "📺 Access your services:"
echo " - Jellyfin:       http://$(hostname -I | awk '{print $1}'):8096"
echo " - qBittorrent:    http://$(hostname -I | awk '{print $1}'):8080 (user: admin / pass: adminadmin)"
echo " - Jackett:        http://$(hostname -I | awk '{print $1}'):9117"
echo " - Sonarr:         http://$(hostname -I | awk '{print $1}'):8989"
echo " - Radarr:         http://$(hostname -I | awk '{print $1}'):7878"
echo ""
echo "⚙ Next steps:"
echo " - In Sonarr/Radarr: Add Jackett indexers (Torznab) and connect qBittorrent"
echo " - Set download folder: $DOWNLOADS_DIR"
echo " - Set media folders in Jellyfin: $TV_DIR and $MOVIES_DIR"
