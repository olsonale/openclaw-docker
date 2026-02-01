#!/bin/sh
set -e

# Use HOME from environment, default to /home/node
USER_HOME="${HOME:-/home/node}"

# Check if we're running as PID 1 (container startup) or exec'd into existing container
is_container_startup() {
  [ "$$" = "1" ] || [ ! -f /tmp/.openclaw-init-done ]
}

if is_container_startup; then
  # Container startup: need to do privileged setup first

  # Ensure config directories exist and are owned by node user
  # (fixes Docker creating bind-mount directories as root:root)
  mkdir -p "$USER_HOME/.openclaw" "$USER_HOME/.moltbot" "$USER_HOME/.clawdbot" "$USER_HOME/clawd"
  chown -R node:node "$USER_HOME/.openclaw" "$USER_HOME/.moltbot" "$USER_HOME/.clawdbot" "$USER_HOME/clawd"

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
