#!/usr/bin/env bash
# =============================================================================
# CoreMP135 - IoT Gateway Provisioning Script
# =============================================================================
# Configures a fresh M5Stack CoreMP135 (Debian ARM7) with:
#   - Docker + Docker Compose
#   - ThingsBoard IoT Gateway (all connectors enabled)
#   - Tailscale reverse VPN
#
# Usage (one-liner from GitHub):
#   curl -sSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/setup.sh \
#     | bash -s -- \
#         --tb-host=enermon.energroup.ch \
#         --tb-provision-key=YOUR_KEY \
#         --tb-provision-secret=YOUR_SECRET \
#         --tailscale-key=tskey-auth-XXXXX
#
# Usage with a local .env file:
#   wget https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/setup.sh
#   chmod +x setup.sh
#   cp .env.example .env && nano .env
#   sudo ./setup.sh --env-file=.env
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colors & logging
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
TB_GW_HOST=""
TB_GW_PORT="8883"
TB_GW_PROVISIONING_DEVICE_KEY=""
TB_GW_PROVISIONING_DEVICE_SECRET=""
TAILSCALE_AUTH_KEY=""
TAILSCALE_HOSTNAME=""      # Auto-detected if empty
INSTALL_DIR="/opt/tb-gateway"
ENV_FILE=""

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
parse_args() {
    for arg in "$@"; do
        case $arg in
            --tb-host=*)              TB_GW_HOST="${arg#*=}" ;;
            --tb-port=*)              TB_GW_PORT="${arg#*=}" ;;
            --tb-provision-key=*)     TB_GW_PROVISIONING_DEVICE_KEY="${arg#*=}" ;;
            --tb-provision-secret=*)  TB_GW_PROVISIONING_DEVICE_SECRET="${arg#*=}" ;;
            --tailscale-key=*)        TAILSCALE_AUTH_KEY="${arg#*=}" ;;
            --tailscale-hostname=*)   TAILSCALE_HOSTNAME="${arg#*=}" ;;
            --install-dir=*)          INSTALL_DIR="${arg#*=}" ;;
            --env-file=*)             ENV_FILE="${arg#*=}" ;;
            --help|-h)                usage; exit 0 ;;
            *) warn "Unknown argument: $arg" ;;
        esac
    done

    # Load from .env file if specified
    if [[ -n "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" ]] || error ".env file not found: $ENV_FILE"
        log "Loading configuration from $ENV_FILE"
        set -o allexport
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +o allexport
    fi
}

usage() {
    cat <<EOF
Usage: setup.sh [OPTIONS]

Required:
  --tb-host=HOST               ThingsBoard server hostname
  --tb-provision-key=KEY       Provisioning device key
  --tb-provision-secret=SECRET Provisioning device secret
  --tailscale-key=KEY          Tailscale auth key (tskey-auth-...) or 'none' to skip

Optional:
  --tb-port=PORT               ThingsBoard MQTT port (default: 8883)
  --tailscale-hostname=NAME    Tailscale hostname override (default: coremp135-<MAC>)
  --install-dir=DIR            Installation directory (default: /opt/tb-gateway)
  --env-file=FILE              Load all config from a .env file
  --help                       Show this help
EOF
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
validate_args() {
    local errors=0
    [[ -z "$TB_GW_HOST" ]]                       && { warn "Missing --tb-host"; ((errors++)); }
    [[ -z "$TB_GW_PROVISIONING_DEVICE_KEY" ]]    && { warn "Missing --tb-provision-key"; ((errors++)); }
    [[ -z "$TB_GW_PROVISIONING_DEVICE_SECRET" ]] && { warn "Missing --tb-provision-secret"; ((errors++)); }
    [[ -z "$TAILSCALE_AUTH_KEY" ]]               && { warn "Missing --tailscale-key (use 'none' to skip)"; ((errors++)); }
    [[ $errors -gt 0 ]] && error "Missing required arguments. Run with --help for usage."
}

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || error "Must be run as root. Try: sudo bash setup.sh ..."
}

check_network() {
    log "Checking network connectivity..."
    if ! curl -sf --max-time 15 https://captive.apple.com > /dev/null 2>&1; then
        error "No internet connection detected. Check your network."
    fi
    success "Network OK"
}

get_eth0_mac() {
    local mac
    # Try sysfs first, fall back to ip command
    if [[ -f /sys/class/net/eth0/address ]]; then
        mac=$(cat /sys/class/net/eth0/address)
    else
        mac=$(ip link show eth0 2>/dev/null | awk '/ether/ {print $2}')
    fi
    # Last resort: grab first real NIC
    if [[ -z "$mac" || "$mac" == "00:00:00:00:00:00" ]]; then
        mac=$(ip link | awk '/ether/ && !/00:00:00:00:00:00/ {print $2; exit}')
    fi
    [[ -z "$mac" ]] && error "Cannot determine eth0 MAC address"
    echo "$mac"
}

# -----------------------------------------------------------------------------
# System packages
# -----------------------------------------------------------------------------
install_prerequisites() {
    log "Updating package lists..."
    apt-get update -qq

    log "Installing prerequisites..."
    apt-get install -y -qq \
        curl \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        net-tools \
        jq \
        wget

    success "Prerequisites OK"
}

# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------
install_docker() {
    if command -v docker &>/dev/null; then
        success "Docker already installed: $(docker --version)"
        return 0
    fi

    log "Installing Docker (official get.docker.com script)..."
    curl -fsSL https://get.docker.com | sh

    systemctl enable docker
    systemctl start docker

    success "Docker installed: $(docker --version)"
}

install_docker_compose() {
    if docker compose version &>/dev/null 2>&1; then
        success "Docker Compose plugin already available: $(docker compose version)"
        return 0
    fi

    log "Installing Docker Compose plugin..."
    apt-get install -y -qq docker-compose-plugin

    success "Docker Compose: $(docker compose version)"
}

# -----------------------------------------------------------------------------
# ThingsBoard IoT Gateway
# -----------------------------------------------------------------------------
setup_tb_gateway() {
    local mac_address="$1"

    log "Setting up ThingsBoard IoT Gateway in ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"

    # Pull latest image
    log "Pulling latest thingsboard/tb-gateway image..."
    docker pull thingsboard/tb-gateway:latest
    success "Image pulled"

    # Generate docker-compose.yml
    cat > "${INSTALL_DIR}/docker-compose.yml" <<'COMPOSEFILE'
# =============================================================================
# ThingsBoard IoT Gateway — generated by setup.sh
# Do not edit manually; re-run setup.sh to update.
# =============================================================================
services:
  tb-gateway:
    image: thingsboard/tb-gateway:latest
    container_name: tb-gateway
    restart: always

    # ---- Connector ports (all enabled) --------------------------------------
    ports:
      - "5000:5000"         # REST connector
      - "1052:1052"         # BACnet connector
      - "5026:5026"         # Modbus TCP (Slave mode)
      - "50000:50000/tcp"   # Socket connector — TCP
      - "50000:50000/udp"   # Socket connector — UDP
      - "47808:47808/udp"   # BACnet/IP (standard port)
      - "502:502"           # Modbus TCP (Master → slave, standard port)
      - "4840:4840"         # OPC-UA server

    # Required for "host" network services (e.g. local Modbus/BACnet devices)
    extra_hosts:
      - "host.docker.internal:host-gateway"

    # Environment loaded from .env file (generated at provision time)
    env_file:
      - .env

    volumes:
      - tb-gw-config:/thingsboard_gateway/config
      - tb-gw-logs:/thingsboard_gateway/logs
      - tb-gw-extensions:/thingsboard_gateway/extensions

volumes:
  tb-gw-config:
    name: tb-gw-config
  tb-gw-logs:
    name: tb-gw-logs
  tb-gw-extensions:
    name: tb-gw-extensions
COMPOSEFILE

    # Generate runtime .env (never committed to git)
    cat > "${INSTALL_DIR}/.env" <<ENVFILE
# ThingsBoard IoT Gateway — runtime config
# Generated by setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
TB_GW_HOST=${TB_GW_HOST}
TB_GW_PORT=${TB_GW_PORT}
TB_GW_PROVISIONING_DEVICE_KEY=${TB_GW_PROVISIONING_DEVICE_KEY}
TB_GW_PROVISIONING_DEVICE_SECRET=${TB_GW_PROVISIONING_DEVICE_SECRET}
TB_GW_PROVISIONING_DEVICE_NAME=${mac_address}
ENVFILE

    chmod 600 "${INSTALL_DIR}/.env"
    success ".env written (permissions 600)"

    # Start gateway
    log "Starting ThingsBoard IoT Gateway..."
    docker compose -f "${INSTALL_DIR}/docker-compose.yml" up -d
    success "TB Gateway container started"
}

# -----------------------------------------------------------------------------
# systemd service — ensures docker-compose restarts after host reboot
# -----------------------------------------------------------------------------
setup_autostart() {
    log "Creating systemd service for auto-start on boot..."

    cat > /etc/systemd/system/tb-gateway.service <<UNITFILE
[Unit]
Description=ThingsBoard IoT Gateway
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNITFILE

    systemctl daemon-reload
    systemctl enable tb-gateway.service
    success "systemd service tb-gateway enabled"
}

# -----------------------------------------------------------------------------
# Tailscale — reverse VPN
# -----------------------------------------------------------------------------
install_tailscale() {
    if [[ "$TAILSCALE_AUTH_KEY" == "none" ]]; then
        warn "Tailscale skipped (--tailscale-key=none)"
        return 0
    fi

    # Install if not present
    if ! command -v tailscale &>/dev/null; then
        log "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        success "Tailscale installed"
    else
        success "Tailscale already installed: $(tailscale version | head -1)"
    fi

    systemctl enable --now tailscaled

    # Build hostname: use override or derive from MAC (colons replaced by dashes)
    local ts_hostname="$TAILSCALE_HOSTNAME"
    if [[ -z "$ts_hostname" ]]; then
        local mac
        mac=$(get_eth0_mac)
        ts_hostname="coremp135-${mac//:/-}"
    fi

    log "Connecting to Tailscale (hostname: ${ts_hostname})..."
    tailscale up \
        --authkey="$TAILSCALE_AUTH_KEY" \
        --hostname="$ts_hostname" \
        --accept-routes \
        --accept-dns=false \
        --ssh

    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "pending")
    success "Tailscale connected — IP: ${ts_ip}"
}

# -----------------------------------------------------------------------------
# Final status
# -----------------------------------------------------------------------------
print_summary() {
    local mac_address="$1"
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "N/A (check: tailscale status)")

    echo ""
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo -e "${GREEN}${BOLD}  Setup completed successfully!${NC}"
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo ""
    echo -e "  ${BOLD}Device${NC}"
    echo -e "    MAC (eth0):        ${mac_address}"
    echo -e "    Tailscale IP:      ${ts_ip}"
    echo ""
    echo -e "  ${BOLD}ThingsBoard Gateway${NC}"
    echo -e "    Server:            ${TB_GW_HOST}:${TB_GW_PORT}"
    echo -e "    Device name:       ${mac_address}"
    echo -e "    Install dir:       ${INSTALL_DIR}"
    echo ""
    echo -e "  ${BOLD}Useful commands${NC}"
    echo -e "    docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f"
    echo -e "    docker compose -f ${INSTALL_DIR}/docker-compose.yml ps"
    echo -e "    tailscale status"
    echo -e "    systemctl status tb-gateway"
    echo ""
}

# =============================================================================
# Entry point
# =============================================================================
main() {
    echo ""
    echo -e "${BLUE}${BOLD}============================================================${NC}"
    echo -e "${BLUE}${BOLD}  CoreMP135 — IoT Gateway Provisioning${NC}"
    echo -e "${BLUE}${BOLD}============================================================${NC}"
    echo ""

    parse_args "$@"
    validate_args
    check_root
    check_network

    local mac_address
    mac_address=$(get_eth0_mac)
    log "eth0 MAC address: ${mac_address}"

    install_prerequisites
    install_docker
    install_docker_compose
    setup_tb_gateway "$mac_address"
    setup_autostart
    install_tailscale

    print_summary "$mac_address"
}

main "$@"
