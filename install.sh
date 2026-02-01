#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
EXTRA_COMPOSE_FILE="$ROOT_DIR/docker-compose.extra.yml"
IMAGE_NAME="${OPENCLAW_IMAGE:-openclaw:local}"
EXTRA_MOUNTS="${OPENCLAW_EXTRA_MOUNTS:-}"
HOME_VOLUME_NAME="${OPENCLAW_HOME_VOLUME:-}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    exit 1
  fi
}

require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose not available (try: docker compose version)" >&2
  exit 1
fi

ENV_FILE="$ROOT_DIR/.env"

# ============================================================================
# Helper Functions for Interactive Prompts
# ============================================================================

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local result
  read -rp "$prompt [$default]: " result
  echo "${result:-$default}"
}

prompt_select() {
  local prompt="$1"
  local default="$2"
  shift 2
  local -a options=("$@")
  local choice

  echo "$prompt"
  local i=1
  for opt in "${options[@]}"; do
    echo "  $i) $opt"
    ((i++))
  done

  while true; do
    read -rp "Choice [1-${#options[@]}] (default: $default): " choice
    choice="${choice:-$default}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "$choice"
      return
    fi
    echo "Please enter a number between 1 and ${#options[@]}"
  done
}

validate_port() {
  local port="$1"
  if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
    return 0
  fi
  return 1
}

prompt_port() {
  local prompt="$1"
  local default="$2"
  local port

  while true; do
    read -rp "$prompt [$default]: " port
    port="${port:-$default}"
    if validate_port "$port"; then
      echo "$port"
      return
    fi
    echo "Please enter a valid port number (1-65535)"
  done
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  fi
}

load_existing_config() {
  if [[ -f "$ENV_FILE" ]]; then
    # Source existing config, but don't fail on missing variables
    set +u
    source "$ENV_FILE"
    set -u
    return 0
  fi
  return 1
}

config_exists() {
  [[ -f "$ENV_FILE" ]] && grep -q "OPENCLAW_GATEWAY_TOKEN" "$ENV_FILE" 2>/dev/null
}

show_current_config() {
  echo ""
  echo "Current configuration:"
  echo "  Config directory: ${OPENCLAW_CONFIG_DIR:-not set}"
  echo "  Workspace: ${OPENCLAW_WORKSPACE_DIR:-not set}"
  echo "  Gateway port: ${OPENCLAW_GATEWAY_PORT:-not set}"
  echo "  Bridge port: ${OPENCLAW_BRIDGE_PORT:-not set}"
  echo "  Bind mode: ${OPENCLAW_GATEWAY_BIND:-not set}"
  if [[ -n "${TS_AUTHKEY:-}" ]]; then
    echo "  Tailscale: enabled"
  else
    echo "  Tailscale: disabled"
  fi
  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    echo "  Token: ${OPENCLAW_GATEWAY_TOKEN:0:8}... (truncated)"
  fi
  echo ""
}

# ============================================================================
# Interactive Configuration Flow
# ============================================================================

run_interactive_config() {
  echo ""
  echo "======================================"
  echo "  OpenClaw Docker Installation"
  echo "======================================"
  echo ""

  if config_exists; then
    load_existing_config
    show_current_config

    echo "[R]econfigure, [K]eep existing, [Q]uit"
    read -rp "Choice [K]: " config_choice
    config_choice="${config_choice:-K}"

    case "${config_choice^^}" in
      R)
        echo ""
        echo "Starting reconfiguration..."
        ;;
      Q)
        echo "Exiting."
        exit 0
        ;;
      *)
        echo "Keeping existing configuration."
        return 0
        ;;
    esac
  else
    echo "No existing configuration found. Starting fresh setup."
  fi

  echo ""
  echo "Press Enter to accept defaults shown in brackets."
  echo ""

  # Directory configuration
  local default_config_dir="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
  OPENCLAW_CONFIG_DIR=$(prompt_with_default "Config directory" "$default_config_dir")

  local default_workspace_dir="${OPENCLAW_WORKSPACE_DIR:-$OPENCLAW_CONFIG_DIR/workspace}"
  OPENCLAW_WORKSPACE_DIR=$(prompt_with_default "Workspace directory" "$default_workspace_dir")
  echo ""

  # Gateway port
  local default_port="${OPENCLAW_GATEWAY_PORT:-18789}"
  OPENCLAW_GATEWAY_PORT=$(prompt_port "Gateway port" "$default_port")

  # Bridge port (auto-set to gateway + 1)
  OPENCLAW_BRIDGE_PORT=$((OPENCLAW_GATEWAY_PORT + 1))
  echo "Bridge port: $OPENCLAW_BRIDGE_PORT"
  echo ""

  # Bind mode selection
  echo "Select bind mode:"
  local bind_options=(
    "loopback - localhost only (most secure)"
    "lan - local network (recommended)"
    "all - any network (use with caution)"
  )
  local bind_choice
  bind_choice=$(prompt_select "" "2" "${bind_options[@]}")

  case "$bind_choice" in
    1) OPENCLAW_GATEWAY_BIND="loopback" ;;
    2) OPENCLAW_GATEWAY_BIND="lan" ;;
    3)
      OPENCLAW_GATEWAY_BIND="all"
      echo ""
      echo "WARNING: 'all' mode exposes the gateway to any network."
      echo "Make sure you understand the security implications."
      ;;
  esac
  echo ""

  # Tailscale configuration
  read -rp "Enable Tailscale VPN? [y/N]: " ts_enable
  if [[ "${ts_enable,,}" == "y" || "${ts_enable,,}" == "yes" ]]; then
    while true; do
      read -rp "Tailscale auth key: " TS_AUTHKEY
      if [[ -n "$TS_AUTHKEY" ]]; then
        export TS_AUTHKEY
        break
      fi
      echo "Auth key is required when Tailscale is enabled."
    done
  else
    unset TS_AUTHKEY 2>/dev/null || true
  fi
  echo ""

  # Homebrew configuration
  read -rp "Include Homebrew for skill dependencies? [y/N]: " homebrew_enable
  if [[ "${homebrew_enable,,}" == "y" || "${homebrew_enable,,}" == "yes" ]]; then
    OPENCLAW_INCLUDE_HOMEBREW=true
  else
    OPENCLAW_INCLUDE_HOMEBREW=false
  fi
  echo ""

  # Token generation (never prompt, always auto-generate if not set)
  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    echo "Generating secure token..."
    OPENCLAW_GATEWAY_TOKEN=$(generate_token)
  fi

  echo "Configuration complete."
  echo ""
}

# Run the interactive configuration
run_interactive_config

# Create directories with correct ownership for container (node user = UID 1000)
mkdir -p "$OPENCLAW_CONFIG_DIR"
mkdir -p "$OPENCLAW_WORKSPACE_DIR"

# Set ownership to UID 1000 (node user in container) so bind mounts are writable
fix_permissions() {
  local dir="$1"
  if [[ $(id -u) -eq 1000 ]]; then
    # Already running as UID 1000, no change needed
    return 0
  elif [[ $(id -u) -eq 0 ]]; then
    chown -R 1000:1000 "$dir"
  elif command -v sudo >/dev/null 2>&1; then
    echo "Setting permissions on $dir (requires sudo)..."
    sudo chown -R 1000:1000 "$dir"
  else
    echo "WARNING: Cannot set ownership on $dir to UID 1000."
    echo "You may need to run: sudo chown -R 1000:1000 $dir"
    return 1
  fi
}

fix_permissions "$OPENCLAW_CONFIG_DIR" || true
fix_permissions "$OPENCLAW_WORKSPACE_DIR" || true

# Export all configuration variables
export OPENCLAW_CONFIG_DIR
export OPENCLAW_WORKSPACE_DIR
export OPENCLAW_GATEWAY_PORT
export OPENCLAW_BRIDGE_PORT
export OPENCLAW_GATEWAY_BIND
export OPENCLAW_GATEWAY_TOKEN
export OPENCLAW_IMAGE="$IMAGE_NAME"
export OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-}"
export OPENCLAW_INCLUDE_HOMEBREW="${OPENCLAW_INCLUDE_HOMEBREW:-false}"
export OPENCLAW_EXTRA_MOUNTS="$EXTRA_MOUNTS"
export OPENCLAW_HOME_VOLUME="$HOME_VOLUME_NAME"

COMPOSE_FILES=("$COMPOSE_FILE")
COMPOSE_ARGS=()

write_extra_compose() {
  local home_volume="$1"
  shift
  local -a mounts=("$@")
  local mount

  cat >"$EXTRA_COMPOSE_FILE" <<'YAML'
services:
  openclaw-gateway:
    volumes:
YAML

  if [[ -n "$home_volume" ]]; then
    printf '      - %s:/home/node\n' "$home_volume" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s:/home/node/.openclaw\n' "$OPENCLAW_CONFIG_DIR" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s:/home/node/.openclaw/workspace\n' "$OPENCLAW_WORKSPACE_DIR" >>"$EXTRA_COMPOSE_FILE"
  fi

  for mount in "${mounts[@]}"; do
    printf '      - %s\n' "$mount" >>"$EXTRA_COMPOSE_FILE"
  done

  cat >>"$EXTRA_COMPOSE_FILE" <<'YAML'
  openclaw-cli:
    volumes:
YAML

  if [[ -n "$home_volume" ]]; then
    printf '      - %s:/home/node\n' "$home_volume" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s:/home/node/.openclaw\n' "$OPENCLAW_CONFIG_DIR" >>"$EXTRA_COMPOSE_FILE"
    printf '      - %s:/home/node/.openclaw/workspace\n' "$OPENCLAW_WORKSPACE_DIR" >>"$EXTRA_COMPOSE_FILE"
  fi

  for mount in "${mounts[@]}"; do
    printf '      - %s\n' "$mount" >>"$EXTRA_COMPOSE_FILE"
  done

  if [[ -n "$home_volume" && "$home_volume" != *"/"* ]]; then
    cat >>"$EXTRA_COMPOSE_FILE" <<YAML
volumes:
  ${home_volume}:
YAML
  fi
}

VALID_MOUNTS=()
if [[ -n "$EXTRA_MOUNTS" ]]; then
  IFS=',' read -r -a mounts <<<"$EXTRA_MOUNTS"
  for mount in "${mounts[@]}"; do
    mount="${mount#"${mount%%[![:space:]]*}"}"
    mount="${mount%"${mount##*[![:space:]]}"}"
    if [[ -n "$mount" ]]; then
      VALID_MOUNTS+=("$mount")
    fi
  done
fi

if [[ -n "$HOME_VOLUME_NAME" || ${#VALID_MOUNTS[@]} -gt 0 ]]; then
  write_extra_compose "$HOME_VOLUME_NAME" "${VALID_MOUNTS[@]}"
  COMPOSE_FILES+=("$EXTRA_COMPOSE_FILE")
fi
for compose_file in "${COMPOSE_FILES[@]}"; do
  COMPOSE_ARGS+=("-f" "$compose_file")
done
COMPOSE_HINT="docker compose"
for compose_file in "${COMPOSE_FILES[@]}"; do
  COMPOSE_HINT+=" -f ${compose_file}"
done

upsert_env() {
  local file="$1"
  shift
  local -a keys=("$@")
  local tmp
  tmp="$(mktemp)"
  declare -A seen=()

  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      local key="${line%%=*}"
      local replaced=false
      for k in "${keys[@]}"; do
        if [[ "$key" == "$k" ]]; then
          printf '%s=%s\n' "$k" "${!k-}" >>"$tmp"
          seen["$k"]=1
          replaced=true
          break
        fi
      done
      if [[ "$replaced" == false ]]; then
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$file"
  fi

  for k in "${keys[@]}"; do
    if [[ -z "${seen[$k]:-}" ]]; then
      printf '%s=%s\n' "$k" "${!k-}" >>"$tmp"
    fi
  done

  mv "$tmp" "$file"
}

# Build the list of config keys to save
ENV_KEYS=(
  OPENCLAW_CONFIG_DIR
  OPENCLAW_WORKSPACE_DIR
  OPENCLAW_GATEWAY_PORT
  OPENCLAW_BRIDGE_PORT
  OPENCLAW_GATEWAY_BIND
  OPENCLAW_GATEWAY_TOKEN
  OPENCLAW_IMAGE
  OPENCLAW_EXTRA_MOUNTS
  OPENCLAW_HOME_VOLUME
  OPENCLAW_DOCKER_APT_PACKAGES
  OPENCLAW_INCLUDE_HOMEBREW
)

# Add TS_AUTHKEY if Tailscale is enabled
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  ENV_KEYS+=(TS_AUTHKEY)
fi

upsert_env "$ENV_FILE" "${ENV_KEYS[@]}"

# Build locally or pull from registry based on image name
if [[ "$IMAGE_NAME" == *"/"* ]]; then
  echo "==> Pulling Docker image: $IMAGE_NAME"
  docker pull "$IMAGE_NAME"
else
  echo "==> Building Docker image: $IMAGE_NAME"
  DOCKER_TARGET="runtime"
  if [[ "${OPENCLAW_INCLUDE_HOMEBREW:-false}" == "true" ]]; then
    DOCKER_TARGET="runtime-homebrew"
  fi
  docker build \
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}" \
    --target "$DOCKER_TARGET" \
    -t "$IMAGE_NAME" \
    -f "$ROOT_DIR/Dockerfile" \
    "$ROOT_DIR"
fi

echo ""
echo "==> Onboarding (interactive)"
echo "When prompted:"
echo "  - Gateway bind: lan"
echo "  - Gateway auth: token"
echo "  - Gateway token: $OPENCLAW_GATEWAY_TOKEN"
echo "  - Tailscale exposure: Off"
echo "  - Install Gateway daemon: No"
echo ""
docker compose "${COMPOSE_ARGS[@]}" run --rm openclaw-cli node dist/index.js onboard --no-install-daemon

echo ""
echo "==> Provider setup (optional)"
echo "WhatsApp (QR):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli node dist/index.js providers login"
echo "Telegram (bot token):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli node dist/index.js providers add --provider telegram --token <token>"
echo "Discord (bot token):"
echo "  ${COMPOSE_HINT} run --rm openclaw-cli node dist/index.js providers add --provider discord --token <token>"
echo "Docs: https://docs.openclaw.ai/providers"

echo ""
echo "==> Starting gateway"
docker compose "${COMPOSE_ARGS[@]}" up -d openclaw-gateway

echo ""
echo "======================================"
echo "  OpenClaw Gateway Running"
echo "======================================"
echo ""

# Show connection URLs based on bind mode
echo "Connection URLs:"
case "$OPENCLAW_GATEWAY_BIND" in
  loopback)
    echo "  http://localhost:$OPENCLAW_GATEWAY_PORT"
    ;;
  lan)
    echo "  http://localhost:$OPENCLAW_GATEWAY_PORT"
    # Try to get the local IP address
    if command -v hostname >/dev/null 2>&1; then
      local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
      if [[ -n "$local_ip" ]]; then
        echo "  http://${local_ip}:$OPENCLAW_GATEWAY_PORT"
      fi
    fi
    ;;
  all)
    echo "  http://localhost:$OPENCLAW_GATEWAY_PORT"
    echo "  http://<your-ip>:$OPENCLAW_GATEWAY_PORT"
    ;;
esac

if [[ -n "${TS_AUTHKEY:-}" ]]; then
  echo "  (Tailscale: accessible via your tailnet)"
fi

echo ""
echo "Configuration:"
echo "  Config directory: $OPENCLAW_CONFIG_DIR"
echo "  Workspace: $OPENCLAW_WORKSPACE_DIR"
echo "  Bind mode: $OPENCLAW_GATEWAY_BIND"
echo ""
echo "Authentication Token:"
echo "  $OPENCLAW_GATEWAY_TOKEN"
echo ""
echo "Commands:"
echo "  View logs:     ${COMPOSE_HINT} logs -f openclaw-gateway"
echo "  Stop:          ${COMPOSE_HINT} down"
echo "  Restart:       ${COMPOSE_HINT} restart openclaw-gateway"
echo "  Reconfigure:   ./install.sh"
echo "  Health check:  curl -s http://localhost:${OPENCLAW_GATEWAY_PORT}/health"
echo ""
