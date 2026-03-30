#!/bin/bash
# =============================================================================
# setup_webserver.sh — DMZ Host Setup Script
# Deploys Flask via Gunicorn + Nginx on the DMZ host (192.168.20.10)
# Run this script ON THE DMZ HOST as a user with sudo privileges.
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
APP_USER="${SUDO_USER:-$(whoami)}"
APP_DIR="/home/${APP_USER}/webapp"
VENV_DIR="${APP_DIR}/venv"
APP_FILE="webserver.py"
SERVICE_NAME="flask_app"
NGINX_SITE="flask_app"
GUNICORN_PORT=5000
NGINX_PORT=80
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Must be run with sudo
[[ $EUID -ne 0 ]] && error "Run this script with sudo: sudo bash $0"

# =============================================================================
# STEP 1 — System dependencies
# =============================================================================
info "Updating package index..."
apt-get update -qq

info "Installing Python3, venv, and Nginx..."
apt-get install -y python3 python3-venv python3-full nginx

# =============================================================================
# STEP 2 — Python virtual environment and dependencies
# =============================================================================
info "Creating Python virtual environment at ${VENV_DIR}..."
mkdir -p "${APP_DIR}"
python3 -m venv "${VENV_DIR}"

info "Installing Flask and Gunicorn inside venv..."
"${VENV_DIR}/bin/pip" install --quiet flask gunicorn

# =============================================================================
# STEP 3 — Application directory and source file
# =============================================================================
info "Setting up application directory at ${APP_DIR}..."
APP_PATH="${APP_DIR}/${APP_FILE}"

if [[ -f "${APP_PATH}" ]]; then
    warn "${APP_PATH} already exists — skipping creation."
else
    info "Writing ${APP_FILE}..."
    cat > "${APP_PATH}" <<'PYEOF'
from flask import Flask
app = Flask(__name__)

@app.route('/')
def home():
    return "<h1>Hello from my Ubuntu Server!</h1>"

if __name__ == "__main__":
    app.run(host='0.0.0.0')
PYEOF
fi

chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

# =============================================================================
# STEP 4 — Systemd service for Gunicorn
# =============================================================================
GUNICORN_BIN="${VENV_DIR}/bin/gunicorn"

info "Creating systemd service: ${SERVICE_NAME}..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Gunicorn instance for Flask app
After=network.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${GUNICORN_BIN} --workers 3 --bind 127.0.0.1:${GUNICORN_PORT} ${APP_FILE%.py}:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

info "Gunicorn service started. Verifying it is listening on 127.0.0.1:${GUNICORN_PORT}..."
sleep 2
ss -tlnp | grep "${GUNICORN_PORT}" || error "Gunicorn does not appear to be listening on port ${GUNICORN_PORT}."

# =============================================================================
# STEP 5 — Nginx reverse proxy configuration
# =============================================================================
info "Configuring Nginx..."

# Remove default site if present
rm -f /etc/nginx/sites-enabled/default

cat > "/etc/nginx/sites-available/${NGINX_SITE}" <<EOF
server {
    listen ${NGINX_PORT};

    location / {
        proxy_pass http://127.0.0.1:${GUNICORN_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# Enable site
ln -sf "/etc/nginx/sites-available/${NGINX_SITE}" "/etc/nginx/sites-enabled/${NGINX_SITE}"

info "Testing Nginx configuration..."
nginx -t || error "Nginx configuration test failed. Check /etc/nginx/sites-available/${NGINX_SITE}."

systemctl enable nginx
systemctl restart nginx

info "Nginx started. Verifying it is listening on port ${NGINX_PORT}..."
sleep 1
ss -tlnp | grep ":${NGINX_PORT}" || error "Nginx does not appear to be listening on port ${NGINX_PORT}."

# =============================================================================
# STEP 6 — Local smoke test
# =============================================================================
info "Running local smoke test via curl..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1)
if [[ "${RESPONSE}" == "200" ]]; then
    info "Smoke test passed — HTTP 200 OK."
else
    warn "Smoke test returned HTTP ${RESPONSE}. Check Gunicorn and Nginx logs."
fi

# =============================================================================
# DONE — Print firewall instructions
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} DMZ host setup complete.${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  App directory : ${APP_DIR}"
echo "  Gunicorn      : 127.0.0.1:${GUNICORN_PORT} (internal only)"
echo "  Nginx         : 0.0.0.0:${NGINX_PORT} (public)"
echo ""
echo -e "${YELLOW}Next: Run the following commands ON THE EDGE-FIREWALL${NC}"
echo "to forward internet traffic to this host:"
echo ""
echo "  sudo iptables -t nat -A PREROUTING -i ens160 -p tcp --dport 80 -j DNAT --to-destination $(hostname -I | awk '{print $1}'):${NGINX_PORT}"
echo "  sudo iptables -A FORWARD -i ens160 -o ens192 -p tcp --dport ${NGINX_PORT} -d $(hostname -I | awk '{print $1}') -j ACCEPT"
echo "  sudo netfilter-persistent save"
echo ""
echo -e "${YELLOW}Then test from an external machine:${NC}"
echo "  curl http://<WAN_IP>"
echo ""
