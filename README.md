# OpenClaw Docker

Dockerized deployment for OpenClaw - an AI-powered coding assistant with gateway and CLI modes.

## Features

- **Gateway Mode**: Run as a persistent service with REST API access
- **CLI Mode**: Interactive terminal interface
- **Tailscale Integration**: Optional VPN for secure remote access
- **Homebrew Support**: Install additional tools via Homebrew skills

## Quick Start

### 1. Clone and Configure

```bash
git clone https://github.com/olsonale/openclaw-docker.git
cd openclaw-docker
```

### 2. Set Required Variables

Create `.env` and set:

```bash
# Required directories (create these first)
CLAWDBOT_CONFIG_DIR=~/.openclaw
CLAWDBOT_WORKSPACE_DIR=~/openclaw-workspace

# Required for gateway authentication
OPENCLAW_GATEWAY_TOKEN=your-secure-random-token
```

### 3. Build and Run

```bash
# Build the image
docker build -t openclaw:local .

# Start the gateway service
docker compose up -d openclaw-gateway

# Or run interactive CLI
docker compose run --rm openclaw-cli
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `CLAWDBOT_CONFIG_DIR` | Yes | - | Host path for OpenClaw config |
| `CLAWDBOT_WORKSPACE_DIR` | Yes | - | Host path for workspace files |
| `OPENCLAW_GATEWAY_TOKEN` | Yes | - | Authentication token for gateway |
| `OPENCLAW_GATEWAY_PORT` | No | `18789` | Gateway API port |
| `OPENCLAW_BRIDGE_PORT` | No | `18790` | Bridge service port |
| `OPENCLAW_GATEWAY_BIND` | No | `loopback` | Bind mode: `loopback`, `lan`, or `all` |
| `CLAUDE_AI_SESSION_KEY` | No | - | Claude AI authentication |
| `TS_AUTHKEY` | No | - | Tailscale auth key for VPN |

### Network Binding Modes

- **loopback**: Only accessible from localhost (most secure)
- **lan**: Accessible from local network
- **all**: Accessible from anywhere (use with caution)

### Tailscale VPN (Optional)

For remote access via Tailscale:

1. Generate an auth key at https://login.tailscale.com/admin/settings/keys
2. Set `TS_AUTHKEY` in your `.env` file
3. The container will automatically connect to your Tailnet

## Services

### Gateway Service

Persistent background service exposing the API:

```bash
docker compose up -d openclaw-gateway
```

Access at `http://localhost:18789` (or your configured port).

### CLI Service

Interactive terminal session:

```bash
docker compose run --rm openclaw-cli
```

## Building with Custom Packages

Install additional apt packages during build:

```bash
docker build \
  --build-arg OPENCLAW_DOCKER_APT_PACKAGES="ffmpeg imagemagick" \
  -t openclaw:custom .
```

## Health Checks

The container includes a health check endpoint. Check container health:

```bash
docker inspect --format='{{.State.Health.Status}}' openclaw-gateway
```

## Troubleshooting

### Container won't start

1. Ensure required directories exist:
   ```bash
   mkdir -p ~/.openclaw ~/openclaw-workspace
   ```

2. Check logs:
   ```bash
   docker compose logs openclaw-gateway
   ```

### Tailscale not connecting

1. Verify your auth key is valid and not expired
2. Check Tailscale state directory permissions:
   ```bash
   ls -la ./tailscale-state
   ```

### Permission issues

The container runs processes as the `node` user (UID 1000). Ensure your mounted directories are accessible:

```bash
chmod 755 ~/.openclaw ~/openclaw-workspace
```

## License

MIT License - see [LICENSE](LICENSE) for details.
