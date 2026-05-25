#!/usr/bin/env bash
# install.sh — camrecord installer
# Supports: Debian/Ubuntu (apt), Fedora/RHEL (dnf), Arch (pacman)
set -euo pipefail

# ── colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
info() { echo -e "${CYAN}  →${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
die()  { echo -e "${RED}  ✗ ERROR:${NC} $*" >&2; exit 1; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        camrecord  installer          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# ── must run as root ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"

# ── detect install dir (where this script lives) ──────────────────────────────
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
info "Install directory: ${INSTALL_DIR}"

# ── check required files ──────────────────────────────────────────────────────
for f in config.json record.sh server.py viewer.html; do
  [[ -f "${INSTALL_DIR}/${f}" ]] || die "Missing required file: ${INSTALL_DIR}/${f}"
done
ok "All required files present"

# ── detect OS / package manager ───────────────────────────────────────────────
detect_os() {
  if command -v apt-get &>/dev/null; then echo "apt"
  elif command -v dnf &>/dev/null;     then echo "dnf"
  elif command -v pacman &>/dev/null;  then echo "pacman"
  else echo "unknown"
  fi
}

PM=$(detect_os)
case "$PM" in
  apt)
    info "Detected: Debian / Ubuntu (apt)"
    apt-get update -qq
    PKGS=()
    command -v ffmpeg  &>/dev/null || PKGS+=(ffmpeg)
    command -v jq      &>/dev/null || PKGS+=(jq)
    command -v python3 &>/dev/null || PKGS+=(python3)
    if [[ ${#PKGS[@]} -gt 0 ]]; then
      info "Installing: ${PKGS[*]}"
      apt-get install -y "${PKGS[@]}"
    fi
    ;;
  dnf)
    info "Detected: Fedora / RHEL (dnf)"
    PKGS=()
    command -v ffmpeg  &>/dev/null || PKGS+=(ffmpeg)
    command -v jq      &>/dev/null || PKGS+=(jq)
    command -v python3 &>/dev/null || PKGS+=(python3)
    if [[ ${#PKGS[@]} -gt 0 ]]; then
      info "Installing: ${PKGS[*]}"
      dnf install -y "${PKGS[@]}"
    fi
    ;;
  pacman)
    info "Detected: Arch Linux (pacman)"
    PKGS=()
    command -v ffmpeg  &>/dev/null || PKGS+=(ffmpeg)
    command -v jq      &>/dev/null || PKGS+=(jq)
    command -v python3 &>/dev/null || PKGS+=(python3)
    if [[ ${#PKGS[@]} -gt 0 ]]; then
      info "Installing: ${PKGS[*]}"
      pacman -Sy --noconfirm "${PKGS[@]}"
    fi
    ;;
  *)
    warn "Unknown package manager — skipping auto-install"
    warn "Please manually install: ffmpeg, jq, python3"
    ;;
esac
ok "Dependencies satisfied"

# ── read config ───────────────────────────────────────────────────────────────
OUTPUT_BASE=$(python3 -c "import json,sys; print(json.load(open('${INSTALL_DIR}/config.json'))['output_base'])")
info "Recordings directory: ${OUTPUT_BASE}"

# ── get the user who owns the install dir ────────────────────────────────────
OWNER=$(stat -c '%U' "${INSTALL_DIR}")
info "Running services as user: ${OWNER}"

# ── create recordings directory ───────────────────────────────────────────────
mkdir -p "${OUTPUT_BASE}"
chown "${OWNER}:${OWNER}" "${OUTPUT_BASE}"
chmod 755 "${OUTPUT_BASE}"
ok "Recordings directory ready: ${OUTPUT_BASE}"

# ── make scripts executable ───────────────────────────────────────────────────
chmod +x "${INSTALL_DIR}/record.sh"
chmod +x "${INSTALL_DIR}/cleanup.sh" 2>/dev/null || true
ok "Scripts are executable"

# ── write record.service ──────────────────────────────────────────────────────
cat > /etc/systemd/system/record.service << UNIT
[Unit]
Description=RTSP Camera Chunk Recorder
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${OWNER}
ExecStart=${INSTALL_DIR}/record.sh ${INSTALL_DIR}/config.json
Restart=always
RestartSec=5
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
SyslogIdentifier=camrecord

[Install]
WantedBy=multi-user.target
UNIT
ok "record.service written"

# ── write camara-web.service ──────────────────────────────────────────────────
cat > /etc/systemd/system/camara-web.service << UNIT
[Unit]
Description=Camrecord web server
After=network.target

[Service]
User=${OWNER}
ExecStart=python3 ${INSTALL_DIR}/server.py ${INSTALL_DIR}/config.json
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=camara-web

[Install]
WantedBy=multi-user.target
UNIT
ok "camara-web.service written"

# ── copy service files back to install dir for reference ─────────────────────
cp /etc/systemd/system/record.service     "${INSTALL_DIR}/record.service"
cp /etc/systemd/system/camara-web.service "${INSTALL_DIR}/camara-web.service"

# ── enable and start services ─────────────────────────────────────────────────
info "Reloading systemd..."
systemctl daemon-reload

info "Enabling and starting record.service..."
systemctl enable --now record

info "Enabling and starting camara-web.service..."
systemctl enable --now camara-web

# ── setup crontab for cleanup if cleanup.sh exists ───────────────────────────
if [[ -f "${INSTALL_DIR}/cleanup.sh" ]]; then
  CRON_LINE="0 3 * * * ${INSTALL_DIR}/cleanup.sh 10 >> ${INSTALL_DIR}/cleanup.log 2>&1"
  # add only if not already there
  crontab -u "${OWNER}" -l 2>/dev/null | grep -qF "${INSTALL_DIR}/cleanup.sh" || {
    (crontab -u "${OWNER}" -l 2>/dev/null; echo "${CRON_LINE}") | crontab -u "${OWNER}" -
    ok "Cleanup cron added (daily at 3am, 10 day retention)"
  }
fi

# ── done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           install complete!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""

IP=$(hostname -I | awk '{print $1}')
echo -e "  Web UI   → ${CYAN}http://${IP}:8080${NC}"
echo -e "  Recorder → ${CYAN}systemctl status record${NC}"
echo -e "  Web      → ${CYAN}systemctl status camara-web${NC}"
echo -e "  Logs     → ${CYAN}journalctl -u record -f${NC}"
echo ""
