#!/bin/sh
set -e

# Use HOME from environment, default to /home/node
USER_HOME="${HOME:-/home/node}"

# Check if we need to run privileged init (first run or exec'd into existing container)
# Note: With init: true in docker-compose, tini is PID 1, not this script
needs_privileged_init() {
  [ ! -f /tmp/.openclaw-init-done ]
}

if needs_privileged_init; then
  # Container startup: need to do privileged setup first

  # Ensure config directories exist and are owned by node user
  # (fallback if install.sh didn't set permissions, or Docker created dirs as root)
  for dir in "$USER_HOME/.openclaw" "$USER_HOME/.moltbot" "$USER_HOME/.clawdbot" "$USER_HOME/clawd"; do
    mkdir -p "$dir"
    # Only chown if not already owned by node (UID 1000)
    if [ "$(stat -c %u "$dir" 2>/dev/null)" != "1000" ]; then
      chown -R node:node "$dir" 2>/dev/null || true
    fi
  done

  # Start tailscaled in the background using containerboot's approach
  # Note: Tailscale requires root/CAP_NET_ADMIN, so this runs before dropping privileges
  if [ -n "$TS_AUTHKEY" ]; then
    echo "Starting Tailscale..."
    tailscaled --tun=userspace-networking --statedir="${TS_STATE_DIR:-/var/lib/tailscale}" &

    # Wait for tailscaled to be ready
    sleep 2

    # Authenticate with the auth key (using env var file to avoid exposing in process list)
    tailscale up --authkey="$TS_AUTHKEY" --accept-routes --accept-dns=false --operator=node

    # Clear the auth key from environment after use
    unset TS_AUTHKEY
    echo "Tailscale connected"
  fi

  # Mark init as done so exec'd commands skip privileged setup
  touch /tmp/.openclaw-init-done
fi

# Drop privileges and run the command as 'node' user
exec gosu node "$@"
