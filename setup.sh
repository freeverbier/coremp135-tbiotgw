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
TB_GW_HTTP_PORT="443"      # ThingsBoard HTTPS port for device HTTP API
TB_GW_PROVISIONING_DEVICE_KEY=""
TB_GW_PROVISIONING_DEVICE_SECRET=""
TAILSCALE_AUTH_KEY=""
TAILSCALE_HOSTNAME=""      # Auto-detected if empty
INSTALL_DIR="/opt/tb-gateway"
ENV_FILE=""
ATTR_REPORT_INTERVAL="300" # Attribute report interval in seconds (default: 5 min)
TIMEZONE="Europe/Zurich"   # Default timezone

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
            --tb-http-port=*)         TB_GW_HTTP_PORT="${arg#*=}" ;;
            --attr-interval=*)        ATTR_REPORT_INTERVAL="${arg#*=}" ;;
            --timezone=*)             TIMEZONE="${arg#*=}" ;;
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
  --tb-http-port=PORT          ThingsBoard HTTPS port for device API (default: 443)
  --tailscale-hostname=NAME    Tailscale hostname override (default: coremp135-<MAC>)
  --attr-interval=SECS         Attribute report interval in seconds (default: 300)
  --timezone=TZ                Timezone (default: Europe/Zurich) e.g. Europe/Paris
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
    # Note: use errors=$((errors+1)) not ((errors++)) — under set -e, ((0++)) exits silently
    [[ -z "$TB_GW_HOST" ]]                       && { warn "Missing --tb-host";                             errors=$((errors+1)); }
    [[ -z "$TB_GW_PROVISIONING_DEVICE_KEY" ]]    && { warn "Missing --tb-provision-key";                   errors=$((errors+1)); }
    [[ -z "$TB_GW_PROVISIONING_DEVICE_SECRET" ]] && { warn "Missing --tb-provision-secret";                errors=$((errors+1)); }
    [[ -z "$TAILSCALE_AUTH_KEY" ]]               && { warn "Missing --tailscale-key (use 'none' to skip)"; errors=$((errors+1)); }
    [[ $errors -gt 0 ]] && error "Missing required arguments. Run with --help for usage."

    # Dump resolved config for debugging
    log "Config: TB_GW_HOST=${TB_GW_HOST} PORT=${TB_GW_PORT}"
    log "Config: TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY:0:12}..."
    log "Config: INSTALL_DIR=${INSTALL_DIR}"
}

# -----------------------------------------------------------------------------
# SD card filesystem expansion
# Detects root partition automatically and expands it to fill the disk.
# Safe to run even if already expanded (idempotent).
# -----------------------------------------------------------------------------
expand_filesystem() {
    log "Checking if SD card filesystem needs expansion..."

    # ---- Detect root partition (e.g. /dev/mmcblk0p2 or /dev/sda2) ----------
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//')
    if [[ -z "$root_dev" ]]; then
        warn "Could not determine root device — skipping filesystem expansion"
        return 0
    fi

    # ---- Detect parent disk (strip trailing partition number/suffix) ---------
    local disk disk_name
    disk_name=$(lsblk -no PKNAME "$root_dev" 2>/dev/null)
    if [[ -z "$disk_name" ]]; then
        warn "Could not determine parent disk for $root_dev — skipping"
        return 0
    fi
    disk="/dev/${disk_name}"

    # ---- Detect partition number --------------------------------------------
    # Works for mmcblk0p2 (→ 2) and sda2 (→ 2)
    local part_num
    part_num=$(lsblk -no PARTN "$root_dev" 2>/dev/null)
    if [[ -z "$part_num" ]]; then
        part_num=$(echo "$root_dev" | grep -o '[0-9]*$')
    fi
    if [[ -z "$part_num" ]]; then
        warn "Could not determine partition number for $root_dev — skipping"
        return 0
    fi

    # ---- Check if expansion is actually needed -------------------------------
    # Compare partition end to disk size (in sectors)
    local disk_sectors part_end_sector
    disk_sectors=$(cat "/sys/block/${disk_name}/size" 2>/dev/null || echo 0)
    part_end_sector=$(cat "/sys/block/${disk_name}/$(basename "$root_dev")/start" 2>/dev/null || echo 0)
    part_end_sector=$((part_end_sector + $(cat "/sys/block/${disk_name}/$(basename "$root_dev")/size" 2>/dev/null || echo 0)))

    local free_sectors=$(( disk_sectors - part_end_sector ))
    # Allow up to 2048 sectors slack (1MB) before deciding expansion is needed
    if [[ "$free_sectors" -lt 2048 ]]; then
        success "SD card already fully used by root partition — no expansion needed"
        return 0
    fi

    local free_mb=$(( free_sectors / 2048 ))
    log "Found ~${free_mb}MB of unallocated space after root partition — expanding..."

    # ---- Resize partition ---------------------------------------------------
    # growpart (cloud-guest-utils) is the simplest; fall back to parted
    if command -v growpart &>/dev/null; then
        growpart "$disk" "$part_num" \
            || { warn "growpart reported no change (already full?)"; }
    elif command -v parted &>/dev/null; then
        parted -s "$disk" resizepart "$part_num" 100% \
            || { warn "parted resizepart failed — skipping filesystem expansion"; return 0; }
    else
        warn "Neither growpart nor parted found — cannot expand partition"
        warn "Run: apt install cloud-guest-utils  then re-run setup.sh"
        return 0
    fi

    # Inform kernel of new partition layout
    partprobe "$disk" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 1

    # ---- Resize filesystem (ext4 online resize — no unmount needed) ---------
    if ! command -v resize2fs &>/dev/null; then
        warn "resize2fs not found — partition resized but filesystem not extended"
        warn "Run: apt install e2fsprogs  then: resize2fs $root_dev"
        return 0
    fi

    log "Running resize2fs on $root_dev (online resize, no reboot needed)..."
    resize2fs "$root_dev" \
        || { warn "resize2fs failed — filesystem may need manual intervention"; return 0; }

    local new_size
    new_size=$(df -h / | awk 'NR==2 {print $2}')
    success "Filesystem expanded — root is now ${new_size}"
}

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || error "Must be run as root. Try: sudo bash setup.sh ..."
}

check_network() {
    log "Checking network connectivity..."
    local ok=0
    for host in 1.1.1.1 8.8.8.8; do
        if ping -c1 -W3 "$host" > /dev/null 2>&1; then
            ok=1; break
        fi
    done
    if [[ $ok -eq 0 ]]; then
        error "No internet connection detected (ping 1.1.1.1 and 8.8.8.8 both failed). Check your network."
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
# Timezone + NTP
# -----------------------------------------------------------------------------
setup_timezone() {
    log "Configuring timezone: ${TIMEZONE}..."

    # Validate timezone exists
    if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
        warn "Unknown timezone '${TIMEZONE}' — skipping (keeping current: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone))"
        return 0
    fi

    timedatectl set-timezone "${TIMEZONE}"
    success "Timezone set to ${TIMEZONE}"

    # Ensure chrony is installed (more reliable than systemd-timesyncd on embedded)
    if ! command -v chronyd &>/dev/null; then
        log "Installing chrony (NTP client)..."
        apt-get install -y -qq chrony
    fi

    # Enable and start chrony
    systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true

    # Disable systemd-timesyncd if chrony takes over (avoid conflicts)
    systemctl disable --now systemd-timesyncd 2>/dev/null || true

    # Force immediate time sync
    log "Forcing NTP sync..."
    chronyc makestep 2>/dev/null || true

    # Wait up to 10s for sync
    local synced=0
    for i in $(seq 1 5); do
        if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            synced=1; break
        fi
        sleep 2
    done

    if [[ $synced -eq 1 ]]; then
        success "NTP synchronized — $(date)"
    else
        warn "NTP sync pending — current time: $(date) (will sync once network is stable)"
    fi
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
        wget \
        python3 \
        python3-pil \
        python3-numpy \
        python3-evdev \
        fonts-dejavu-core \
        cloud-guest-utils \
        parted \
        e2fsprogs

    success "Prerequisites OK"
}

# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------
fix_iptables_legacy() {
    # Debian Bookworm defaults to nftables backend which is unsupported on many
    # embedded ARM kernels (CoreMP135 included). Switch to iptables-legacy.
    if command -v update-alternatives &>/dev/null \
        && update-alternatives --list iptables 2>/dev/null | grep -q legacy; then
        log "Switching iptables to legacy backend (nftables unsupported on this kernel)..."
        update-alternatives --set iptables  /usr/sbin/iptables-legacy
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
        success "iptables-legacy set"
    else
        warn "iptables-legacy not found — Docker networking may fail on this kernel"
    fi
}

install_docker() {
    if command -v docker &>/dev/null; then
        success "Docker already installed: $(docker --version)"
        # Still ensure iptables-legacy is set even if Docker was pre-installed
        fix_iptables_legacy
        systemctl restart docker
        return 0
    fi

    log "Installing Docker (official get.docker.com script)..."
    curl -fsSL https://get.docker.com | sh

    # Must fix iptables BEFORE starting Docker on embedded ARM kernels
    fix_iptables_legacy

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

    # Resource limits — important on ARM Cortex-A7 (single core, 256MB RAM)
    deploy:
      resources:
        limits:
          cpus: "0.75"     # max 75% of one core
          memory: 256M
        reservations:
          memory: 64M

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
# TB_GW_DEVICE_NAME sets the gateway device name on ThingsBoard.
# We use the host eth0 MAC so each box gets a unique, traceable identity.
TB_GW_DEVICE_NAME=coremp135-${mac_address}
ENVFILE

    chmod 600 "${INSTALL_DIR}/.env"
    success ".env written (permissions 600)"

    # Start gateway
    log "Starting ThingsBoard IoT Gateway..."
    docker compose -f "${INSTALL_DIR}/docker-compose.yml" up -d
    success "TB Gateway container started"
}

# -----------------------------------------------------------------------------
# Patch TB Gateway config: enable remote logging + remote shell
# Must be called after setup_tb_gateway() — waits for provisioning to finish,
# then injects remoteLoggingLevel + remoteShell into tb_gateway.json.
# -----------------------------------------------------------------------------
patch_tb_gateway_config() {
    log "Waiting for TB Gateway provisioning before patching config..."

    local max_attempts=60   # 5 min max (60 × 5s)
    local attempt=0
    local token=""

    while [[ $attempt -lt $max_attempts ]]; do
        token=$(docker exec tb-gateway \
            python3 -c "
import json, sys
try:
    with open('/thingsboard_gateway/config/tb_gateway.json') as f:
        d = json.load(f)
    tb = d.get('thingsboard', {}) or {}
    t = (tb.get('security', {}).get('accessToken')
         or tb.get('credentials', {}).get('token')
         or tb.get('credentials', {}).get('accessToken')
         or d.get('security', {}).get('accessToken', ''))
    if t and t not in ('YOUR_ACCESS_TOKEN', 'null', ''):
        print(t.strip())
except Exception:
    pass
" 2>/dev/null || true)

        if [[ -n "$token" ]]; then
            log "Provisioning complete (token obtained after $((attempt * 5))s)"
            break
        fi
        sleep 5
        attempt=$((attempt + 1))
    done

    if [[ $attempt -ge $max_attempts ]]; then
        warn "Timed out waiting for provisioning — skipping remote config patch"
        return 0
    fi

    # Patch the JSON inside the running container
    docker exec tb-gateway python3 -c "
import json, sys
cfg = '/thingsboard_gateway/config/tb_gateway.json'
try:
    with open(cfg) as f:
        d = json.load(f)
    tb = d.setdefault('thingsboard', {})
    tb['remoteLoggingLevel'] = 'DEBUG'
    tb['remoteShell']        = True
    with open(cfg, 'w') as f:
        json.dump(d, f, indent=2)
    print('patched OK')
except Exception as e:
    print(f'patch error: {e}', file=sys.stderr)
    sys.exit(1)
" || { warn "Config patch failed — gateway will still work, remote logging disabled"; return 0; }

    # Restart gateway to pick up patched config
    log "Restarting TB Gateway to apply remote logging + remote shell..."
    docker compose -f "${INSTALL_DIR}/docker-compose.yml" restart tb-gateway
    success "TB Gateway patched: remoteLoggingLevel=DEBUG, remoteShell=true"
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
# Attribute reporter — pushes device attributes to ThingsBoard every N seconds
# -----------------------------------------------------------------------------
setup_attribute_reporter() {
    log "Setting up ThingsBoard attribute reporter..."

    # ---- report-attributes.sh -----------------------------------------------
    cat > "${INSTALL_DIR}/report-attributes.sh" <<'REPORTER'
#!/usr/bin/env bash
# =============================================================================
# TB Gateway — Device Attribute Reporter
# Reads device info and pushes it as client-side attributes to ThingsBoard.
# Runs as a systemd service (tb-report-attributes.service).
# =============================================================================

set -euo pipefail

CONFIG_FILE="/thingsboard_gateway/config/tb_gateway.json"
ENV_FILE="/opt/tb-gateway/.env"

log()  { echo "[$(date -u +%H:%M:%S)] [ATTR] $*"; }
warn() { echo "[$(date -u +%H:%M:%S)] [WARN] $*" >&2; }

# Load runtime config (TB_GW_HOST, TB_GW_HTTP_PORT)
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

TB_GW_HOST="${TB_GW_HOST:-}"
TB_GW_HTTP_PORT="${TB_GW_HTTP_PORT:-443}"
ATTR_REPORT_INTERVAL="${ATTR_REPORT_INTERVAL:-300}"

[[ -z "$TB_GW_HOST" ]] && { warn "TB_GW_HOST not set — aborting"; exit 1; }

# ---- Helpers ----------------------------------------------------------------

get_access_token() {
    # TB Gateway stores credentials in tb_gateway.json (JSON, not YAML)
    docker exec tb-gateway \
        sh -c 'cat /thingsboard_gateway/config/tb_gateway.json 2>/dev/null' \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # Try common locations for the access token
    token = (
        d.get('thingsboard', {}).get('security', {}).get('accessToken') or
        d.get('security', {}).get('accessToken') or
        d.get('accessToken') or ''
    )
    print(token.strip())
except Exception:
    pass
" 2>/dev/null || true
}

wait_for_provisioning() {
    log "Waiting for TB Gateway provisioning to complete..."
    local max_attempts=60   # 5 min max (60 × 5s)
    local attempt=0
    local token=""

    while [[ $attempt -lt $max_attempts ]]; do
        token=$(get_access_token 2>/dev/null || true)
        if [[ -n "$token" && "$token" != "null" && "$token" != "YOUR_ACCESS_TOKEN" ]]; then
            log "Access token obtained after $((attempt * 5))s"
            echo "$token"
            return 0
        fi
        sleep 5
        attempt=$((attempt + 1))
    done

    warn "Timed out waiting for provisioning (${max_attempts} attempts)"
    return 1
}

collect_attributes() {
    local mac eth0_ip tailscale_ip os_version tb_image_tag

    # MAC address eth0
    mac=$(cat /sys/class/net/eth0/address 2>/dev/null \
        || ip link show eth0 | awk '/ether/ {print $2}')

    # eth0 IP (exclude 169.254.x.x link-local)
    eth0_ip=$(ip -4 addr show eth0 2>/dev/null \
        | awk '/inet / && !/169\.254/ {print $2}' \
        | cut -d/ -f1 | head -1)
    [[ -z "$eth0_ip" ]] && eth0_ip="unknown"

    # Tailscale IP
    tailscale_ip=$(tailscale ip -4 2>/dev/null || echo "unavailable")

    # OS version (clean string)
    os_version=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" \
        || uname -r)

    # TB Gateway Docker image tag (version)
    tb_image_tag=$(docker inspect tb-gateway \
        --format '{{index .Config.Image}}' 2>/dev/null || echo "unknown")

    # Build JSON payload
    jq -n \
        --arg mac        "$mac" \
        --arg eth0_ip    "$eth0_ip" \
        --arg ts_ip      "$tailscale_ip" \
        --arg hostname   "$(hostname)" \
        --arg os_ver     "$os_version" \
        --arg tb_image   "$tb_image_tag" \
        --arg uptime     "$(awk '{printf "%dd %dh %dm", $1/86400, ($1%86400)/3600, ($1%3600)/60}' /proc/uptime)" \
        '{
            mac_address:    $mac,
            eth0_ip:        $eth0_ip,
            tailscale_ip:   $ts_ip,
            hostname:       $hostname,
            os_version:     $os_ver,
            tb_gateway_image: $tb_image,
            uptime:         $uptime
        }'
}

push_attributes() {
    local token="$1"
    local payload
    payload=$(collect_attributes)

    local url="https://${TB_GW_HOST}:${TB_GW_HTTP_PORT}/api/v1/${token}/attributes"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 15)

    if [[ "$http_code" == "200" ]]; then
        log "Attributes pushed OK — eth0=$(echo "$payload" | jq -r .eth0_ip) tailscale=$(echo "$payload" | jq -r .tailscale_ip)"
    else
        warn "Push failed (HTTP ${http_code}) — will retry at next interval"
    fi
}

# ---- Main loop --------------------------------------------------------------
main() {
    local token
    token=$(wait_for_provisioning) || exit 1

    log "Starting attribute reporter (interval: ${ATTR_REPORT_INTERVAL}s)"

    while true; do
        push_attributes "$token"
        sleep "$ATTR_REPORT_INTERVAL"
    done
}

main
REPORTER

    chmod +x "${INSTALL_DIR}/report-attributes.sh"

    # ---- Inject TB_GW_HTTP_PORT and ATTR_REPORT_INTERVAL into the .env ------
    # (used by report-attributes.sh at runtime)
    if ! grep -q "^TB_GW_HTTP_PORT=" "${INSTALL_DIR}/.env" 2>/dev/null; then
        echo "TB_GW_HTTP_PORT=${TB_GW_HTTP_PORT}" >> "${INSTALL_DIR}/.env"
    fi
    if ! grep -q "^ATTR_REPORT_INTERVAL=" "${INSTALL_DIR}/.env" 2>/dev/null; then
        echo "ATTR_REPORT_INTERVAL=${ATTR_REPORT_INTERVAL}" >> "${INSTALL_DIR}/.env"
    fi

    # ---- systemd service (runs the reporter loop) ---------------------------
    cat > /etc/systemd/system/tb-report-attributes.service <<UNITFILE
[Unit]
Description=ThingsBoard Gateway — Device Attribute Reporter
Requires=tb-gateway.service docker.service
After=tb-gateway.service docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=on-failure
RestartSec=30
ExecStart=${INSTALL_DIR}/report-attributes.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=tb-report-attributes

[Install]
WantedBy=multi-user.target
UNITFILE

    systemctl daemon-reload
    systemctl enable --now tb-report-attributes.service
    success "Attribute reporter service started (interval: ${ATTR_REPORT_INTERVAL}s)"
}

# -----------------------------------------------------------------------------
# Display — diagnostic screen on the built-in 320×240 LCD
# -----------------------------------------------------------------------------
setup_display() {
    log "Setting up diagnostic display..."

    # ---- Kill and disable the default M5Stack UI ----------------------------
    log "Disabling default M5Stack UI..."

    # Known default GUI service names on CoreMP135 Debian images
    local ui_services=("m5stack-ui" "m5stack_ui" "m5ui" "lvgl-demo" "lvgl_demo"
                       "lightdm" "gdm3" "sddm" "display-manager")
    for svc in "${ui_services[@]}"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
            log "Disabling service: ${svc}"
            systemctl stop    "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
        fi
    done

    # Kill any process currently holding /dev/fb1
    local fb_pids
    fb_pids=$(fuser /dev/fb1 2>/dev/null || true)
    if [[ -n "$fb_pids" ]]; then
        log "Killing processes using /dev/fb1: ${fb_pids}"
        for pid in $fb_pids; do
            kill -9 "$pid" 2>/dev/null || true
        done
    fi

    success "Default UI cleared"

    # ---- Install Pillow + evdev (via apt — already in install_prerequisites) -
    local missing=0
    python3 -c "from PIL import Image" 2>/dev/null || { apt-get install -y -qq python3-pil;   missing=1; }
    python3 -c "import evdev"          2>/dev/null || { apt-get install -y -qq python3-evdev; missing=1; }
    success "Pillow + evdev available"

    # ---- Deploy display.py from repo ----------------------------------------
    log "Deploying display.py..."
    # Download from GitHub repo (same as this script)
    local script_base="https://raw.githubusercontent.com/freeverbier/coremp135-tbiotgw/main"
    if curl -fsSL "${script_base}/display.py" -o "${INSTALL_DIR}/display.py" 2>/dev/null; then
        success "display.py downloaded from GitHub"
    else
        warn "Could not download display.py from GitHub — skipping display setup"
        return 0
    fi
    chmod +x "${INSTALL_DIR}/display.py"

    # ---- systemd service for the display ------------------------------------
    cat > /etc/systemd/system/tb-display.service <<UNITFILE
[Unit]
Description=CoreMP135 IoT Gateway Status Display
After=network-online.target docker.service tb-gateway.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
Environment=SDL_VIDEODRIVER=fbcon
Environment=SDL_FBDEV=/dev/fb1
Environment=SDL_AUDIODRIVER=dummy
Environment=SDL_NOMOUSE=1
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/display.py
StandardOutput=journal
StandardError=journal
SyslogIdentifier=tb-display

[Install]
WantedBy=multi-user.target
UNITFILE

    systemctl daemon-reload
    systemctl enable --now tb-display.service
    success "Display service started"
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
    echo -e "    Timezone:          ${TIMEZONE}  ($(date))"
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
    echo -e "    journalctl -u tb-report-attributes -f   # attribute reporter logs"
    echo -e "    journalctl -u tb-display -f            # display service logs"
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
    expand_filesystem        # resize SD card partition + filesystem before anything else
    check_network

    local mac_address
    mac_address=$(get_eth0_mac)
    log "eth0 MAC address: ${mac_address}"

    setup_timezone
    install_prerequisites
    install_docker
    install_docker_compose
    setup_tb_gateway "$mac_address"
    patch_tb_gateway_config          # wait for provisioning → enable remote logging + remote shell
    setup_autostart
    install_tailscale
    setup_attribute_reporter
    setup_display

    print_summary "$mac_address"

    # Reboot to ensure all services start cleanly from a known state
    log ""
    log "============================================================"
    log "  Setup complete — rebooting in 15 seconds"
    log "  Press Ctrl+C to cancel the reboot"
    log "============================================================"
    sleep 15
    reboot
}

main "$@"
