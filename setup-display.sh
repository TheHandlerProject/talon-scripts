#!/bin/bash
# setup-display.sh — Configure dual screen + autostart on Zion
set -euo pipefail

echo "→ Creating Openbox config directories..."
mkdir -p /home/neo/.config/openbox

echo "→ Installing autostart..."
cp /home/neo/inspection/openbox-autostart /home/neo/.config/openbox/autostart
chmod +x /home/neo/.config/openbox/autostart

echo "→ Installing Openbox rc.xml..."
cp /home/neo/inspection/openbox-rc.xml /home/neo/.config/openbox/rc.xml

echo "→ Configuring LightDM autologin..."
sudo cp /home/neo/inspection/lightdm-zion.conf /etc/lightdm/lightdm.conf.d/99-zion.conf

echo "→ Creating Openbox session file..."
sudo bash -c 'cat > /usr/share/xsessions/openbox.desktop << EOF
[Desktop Entry]
Name=Openbox
Comment=Openbox Window Manager
Exec=openbox-session
Type=Application
EOF'

echo "→ Enabling LightDM..."
sudo systemctl enable lightdm
sudo systemctl set-default graphical.target

echo ""
echo "✓ Done. Reboot Zion to start dual screen."
echo "  Super+T = new terminal"
echo "  Super+D = desktop 2 (demo mode)"
echo "  Super+1 = desktop 1 (main)"
