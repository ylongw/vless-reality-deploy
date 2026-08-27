#!/usr/bin/env bash

# Local one-command orchestrator for one Ubuntu VPS, one Reality client, and
# one tokenized subscription URL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.yaml}"
REMOTE_INSTALLER="/tmp/vless-reality-install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

FORCE=false
DRY_RUN=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: ./deploy.sh [--dry-run] [--force]

  --dry-run  Check local dependencies, SSH access, and remote service state.
             Nothing is uploaded or modified.
  --force    Destructively replace an existing Xray Reality identity and
             subscription. Existing clients must import the new link.
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

for command in python3 ssh scp; do
    if ! command -v "$command" >/dev/null 2>&1; then
        log_error "Required local command not found: $command"
        exit 1
    fi
done

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Configuration not found: $CONFIG_FILE"
    log_error "Run: cp config.yaml.example config.yaml"
    exit 1
fi

if ! CONFIG_EXPORTS=$(python3 "$SCRIPT_DIR/read_config.py" --file "$CONFIG_FILE"); then
    exit 1
fi
eval "$CONFIG_EXPORTS"
unset CONFIG_EXPORTS

if [[ ! "$REALITY_SNI" =~ ^[A-Za-z0-9.-]+$ ]]; then
    log_error "server.reality_sni contains unsupported characters"
    exit 1
fi

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
SCP_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [ -n "$SSH_PORT" ]; then
    SSH_OPTS+=(-p "$SSH_PORT")
    SCP_OPTS+=(-P "$SSH_PORT")
fi

if [ "$SSH_MODE" = "password" ]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        log_error "Password mode requires sshpass on the local machine."
        log_error "Install sshpass, or switch ssh.mode to key and use ~/.ssh/config."
        exit 1
    fi
    SSH_TARGET="${SSH_USER:-root}@$SSH_HOST"
    SSH_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
    SCP_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
else
    SSH_TARGET="$SSH_HOST"
    if [ -n "$SSH_USER" ]; then
        SSH_TARGET="$SSH_USER@$SSH_HOST"
    fi
    SSH_OPTS+=(-o BatchMode=yes)
    SCP_OPTS+=(-o BatchMode=yes)
fi

ssh_run() {
    if [ "$SSH_MODE" = "password" ]; then
        SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"
    else
        ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"
    fi
}

scp_to() {
    local source=$1
    local destination=$2
    if [ "$SSH_MODE" = "password" ]; then
        SSHPASS="$SSH_PASSWORD" sshpass -e scp "${SCP_OPTS[@]}" "$source" "$SSH_TARGET:$destination"
    else
        scp "${SCP_OPTS[@]}" "$source" "$SSH_TARGET:$destination"
    fi
}

scp_from() {
    local source=$1
    local destination=$2
    if [ "$SSH_MODE" = "password" ]; then
        SSHPASS="$SSH_PASSWORD" sshpass -e scp "${SCP_OPTS[@]}" "$SSH_TARGET:$source" "$destination"
    else
        scp "${SCP_OPTS[@]}" "$SSH_TARGET:$source" "$destination"
    fi
}

SSH_EFFECTIVE_HOST="$SSH_HOST"
SSH_EFFECTIVE_PORT="${SSH_PORT:-22}"
if [ "$SSH_MODE" = "key" ]; then
    SSH_CONFIG=$(ssh -G "${SSH_OPTS[@]}" "$SSH_TARGET" 2>/dev/null || true)
    RESOLVED_HOST=$(awk '$1 == "hostname" {print $2; exit}' <<<"$SSH_CONFIG")
    RESOLVED_PORT=$(awk '$1 == "port" {print $2; exit}' <<<"$SSH_CONFIG")
    SSH_EFFECTIVE_HOST="${RESOLVED_HOST:-$SSH_HOST}"
    SSH_EFFECTIVE_PORT="${RESOLVED_PORT:-${SSH_PORT:-22}}"
    unset SSH_CONFIG RESOLVED_HOST RESOLVED_PORT
fi

if [ -z "$SERVER_ADDRESS" ]; then
    SERVER_ADDRESS="$SSH_EFFECTIVE_HOST"
fi
SERVER_ADDRESS="${SERVER_ADDRESS#[}"
SERVER_ADDRESS="${SERVER_ADDRESS%]}"

log_info "=========================================="
log_info "VLESS + Reality single-server deployment"
log_info "Config: $CONFIG_FILE"
log_info "SSH mode: $SSH_MODE"
log_info "SSH target: $SSH_TARGET"
log_info "Node address: $SERVER_ADDRESS"
log_info "Reality port: 443"
log_info "Subscription: http://$SERVER_ADDRESS:$SUB_PORT/<token>"
log_info "=========================================="

log_info "Checking SSH access and root privileges..."
REMOTE_INFO=$(ssh_run 'printf "uid=%s\nuser=%s\nhostname=%s\nos=%s\n" "$(id -u)" "$(id -un)" "$(hostname)" "$(. /etc/os-release 2>/dev/null; printf "%s" "${PRETTY_NAME:-unknown}")"')
printf '%s\n' "$REMOTE_INFO"
if ! grep -q '^uid=0$' <<<"$REMOTE_INFO"; then
    log_error "The remote SSH account must be root."
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    log_info "DRY RUN: reading remote service and port state only."
    ssh_run 'set +e
printf "xray_config="; test -f /usr/local/etc/xray/config.json && echo present || echo absent
printf "xray_service="; systemctl is-active xray 2>/dev/null || true
printf "nginx_service="; systemctl is-active nginx 2>/dev/null || true
printf "port_443="; ss -tln 2>/dev/null | grep -q ":443 " && echo listening || echo not-listening
printf "subscription_port="; ss -tln 2>/dev/null | grep -q ":'"$SUB_PORT"' " && echo listening || echo not-listening'
    log_info "DRY RUN complete. No files were uploaded and nothing was modified."
    exit 0
fi

if ssh_run 'test -f /usr/local/etc/xray/config.json'; then
    if [ "$FORCE" != true ]; then
        log_error "Existing Xray configuration found; refusing to overwrite it."
        log_error "Use --force only when you intend to regenerate all client credentials."
        exit 1
    fi
    log_warn "--force will regenerate the Reality key, UUID, short ID, and subscription token."
fi

log_info "Uploading the remote installer..."
scp_to "$SCRIPT_DIR/install_vless.sh" "$REMOTE_INSTALLER"

REMOTE_ARGS=("$SERVER_ADDRESS" "$SUB_PORT" "$NODE_NAME" "$REALITY_SNI" "$SSH_EFFECTIVE_PORT")
if [ "$FORCE" = true ]; then
    REMOTE_ARGS=(--force "${REMOTE_ARGS[@]}")
fi
printf -v INSTALL_COMMAND '%q ' "$REMOTE_INSTALLER" "${REMOTE_ARGS[@]}"

log_info "Installing Xray Reality and the single subscription..."
ssh_run "chmod +x $(printf %q "$REMOTE_INSTALLER"); $INSTALL_COMMAND; rc=\$?; rm -f $(printf %q "$REMOTE_INSTALLER"); exit \$rc"

mkdir -p "$SCRIPT_DIR/output"
OUTPUT_FILE="$SCRIPT_DIR/output/subscription.txt"
scp_from /root/vless_subscription.txt "$OUTPUT_FILE"
chmod 600 "$OUTPUT_FILE"

SUBSCRIPTION_URL=$(awk -F': ' '$1 == "owner" {print $2; exit}' "$OUTPUT_FILE")
if [ -z "$SUBSCRIPTION_URL" ]; then
    log_error "The server did not return a subscription URL."
    exit 1
fi

log_info "Deployment complete."
log_info "Subscription saved to: $OUTPUT_FILE"
printf 'owner: %s\n' "$SUBSCRIPTION_URL"
