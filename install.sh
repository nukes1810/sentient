#!/bin/bash
# sentient installer - https://github.com/nukes1810/sentient
# Usage: bash <(curl -s https://raw.githubusercontent.com/nukes1810/sentient/main/install.sh)

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[sentient]${NC} $1"; }
warn() { echo -e "${YELLOW}[sentient]${NC} $1"; }
err()  { echo -e "${RED}[sentient]${NC} $1"; exit 1; }

echo -e "${BLUE}"
echo "   ___  ___ _ __ | |_(_) ___ _ __ | |_"
echo "  / __|/ _ \ '_ \| __| |/ _ \ '_ \| __|"
echo "  \__ \  __/ | | | |_| |  __/ | | | |_"
echo "  |___/\___|_| |_|\__|_|\___|_| |_|\__|"
echo -e "${NC}"
echo "  sentient — Smart 3D Printer Dashboard"
echo "  https://github.com/nukes1810/sentient"
echo ""

# Detect environment
if [ "$EUID" -eq 0 ]; then
    INSTALL_HOME="/root"
    INSTALL_USER="root"
else
    INSTALL_HOME="$HOME"
    INSTALL_USER="$USER"
fi

SENTIENT_DIR="$INSTALL_HOME/sentient"
SERVER_SCRIPT="$INSTALL_HOME/sentient_server.py"
KLIPPER_EXTRAS="$INSTALL_HOME/klipper/klippy/extras"
PRINTER_CONFIG="$INSTALL_HOME/printer_data/config"
SERVICE_FILE="/etc/systemd/system/sentient.service"
# Port is selected interactively below

log "Home: $INSTALL_HOME | User: $INSTALL_USER"

# Ask for port
echo ""
read -p "  Which port should sentient run on? [default: 8080]: " PORT_INPUT
PORT="${PORT_INPUT:-8080}"
# Validate it's a number
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    warn "Invalid port '$PORT' — using 8080"
    PORT=8080
fi
log "Using port: $PORT"

# Step 1: Clone or update repo
if [ -d "$SENTIENT_DIR/.git" ]; then
    log "Updating sentient repo..."
    cd "$SENTIENT_DIR" && git pull origin main || warn "Git pull failed — using existing files"
else
    [ -d "$SENTIENT_DIR" ] && mv "$SENTIENT_DIR" "${SENTIENT_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    log "Cloning sentient repo..."
    git clone https://github.com/nukes1810/sentient.git "$SENTIENT_DIR" || err "Failed to clone repo"
fi

mkdir -p "$SENTIENT_DIR/dashboard"

# Step 2: Install Klipper modules
if [ -d "$KLIPPER_EXTRAS" ]; then
    log "Installing Klipper modules..."
    for module in sentient_first_layer.py sentient_vl53l5cx.py; do
        if [ -f "$SENTIENT_DIR/klippy/extras/$module" ]; then
            cp "$SENTIENT_DIR/klippy/extras/$module" "$KLIPPER_EXTRAS/"
            log "  $module installed"
        fi
    done
else
    warn "Klipper extras not found at $KLIPPER_EXTRAS — skipping"
fi

# Step 3: Create server script
log "Creating server script..."
cat > "$SERVER_SCRIPT" << SERVEREOF
#!/usr/bin/env python3
import http.server, socketserver, os
PORT = $PORT
DIRECTORY = "$SENTIENT_DIR/dashboard"
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)
    def log_message(self, format, *args): pass
os.makedirs(DIRECTORY, exist_ok=True)
print(f"sentient serving on port {PORT}")
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    httpd.serve_forever()
SERVEREOF
chmod +x "$SERVER_SCRIPT"

# Step 4: Create systemd service
log "Creating systemd service..."
cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=sentient Dashboard
After=network.target moonraker.service
Wants=moonraker.service

[Service]
ExecStart=/usr/bin/python3 $SERVER_SCRIPT
WorkingDirectory=$INSTALL_HOME
Restart=always
RestartSec=5
User=$INSTALL_USER

[Install]
WantedBy=multi-user.target
SVCEOF

# Step 5: Enable and start service
log "Enabling sentient service..."
systemctl daemon-reload
systemctl enable sentient
systemctl restart sentient
sleep 2

# Step 6: Add to moonraker update manager
if [ -f "$PRINTER_CONFIG/moonraker.conf" ]; then
    if ! grep -q "\[update_manager sentient\]" "$PRINTER_CONFIG/moonraker.conf"; then
        log "Adding to Moonraker update manager..."
        cat >> "$PRINTER_CONFIG/moonraker.conf" << MOONEOF

[update_manager sentient]
type: git_repo
path: $SENTIENT_DIR
origin: https://github.com/nukes1810/sentient.git
managed_services: sentient
MOONEOF
    else
        log "Moonraker already configured"
    fi
fi

# Step 7: Add sentient to moonraker.asvc
ASVC="$INSTALL_HOME/printer_data/moonraker.asvc"
if [ -f "$ASVC" ] && ! grep -q "sentient" "$ASVC"; then
    echo "sentient" >> "$ASVC"
    log "Added sentient to moonraker.asvc"
fi

# Step 8: Add sentient_first_layer to printer.cfg if missing
if [ -f "$PRINTER_CONFIG/printer.cfg" ]; then
    if ! grep -q "sentient_first_layer" "$PRINTER_CONFIG/printer.cfg"; then
        log "Adding sentient_first_layer to printer.cfg..."
        cat >> "$PRINTER_CONFIG/printer.cfg" << CFGEOF

[sentient_first_layer]
calibration_x: 30
calibration_y: 30
calibration_size: 40
iterations: 3
tolerance: 0.01
layer_height: 0.20
CFGEOF
    fi
fi

# Done
IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  sentient installed!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Dashboard: ${BLUE}http://$IP:$PORT${NC}"
echo ""
if systemctl is-active --quiet sentient; then
    echo -e "  Service:   ${GREEN}Running ✓${NC}"
else
    echo -e "  Service:   ${RED}Failed ✗${NC} — check: journalctl -u sentient -n 20"
fi
echo ""
echo "  Next: upload dashboard/index.html via WinSCP if needed"
echo "  Then: sudo systemctl restart klipper"
echo ""
