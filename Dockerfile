# ============ BUILDER STAGE ============
FROM node:22-bookworm AS builder

# Install build-essential for native module compilation
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable

# Clone OpenClaw source from upstream
ARG OPENCLAW_VERSION=main
RUN git clone --depth 1 --branch ${OPENCLAW_VERSION} \
    https://github.com/openclaw/openclaw /app

WORKDIR /app

RUN pnpm install --frozen-lockfile

RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
# Force pnpm for UI build (Bun may fail on some ARM architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# Prune dev dependencies for smaller runtime image
RUN CI=true pnpm prune --prod

# ============ RUNTIME STAGE ============
FROM node:22-bookworm

# OCI Image Labels
LABEL org.opencontainers.image.title="OpenClaw Docker"
LABEL org.opencontainers.image.description="Docker setup for OpenClaw - AI-powered coding assistant"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.source="https://github.com/openclaw/openclaw"

# Copy gosu for privilege dropping (faster than apt)
COPY --from=tianon/gosu:1.17 /usr/local/bin/gosu /usr/local/bin/gosu

# Copy Tailscale binaries directly from official image (faster than apt)
COPY --from=tailscale/tailscale:v1.76.6 /usr/local/bin/containerboot /usr/local/bin/containerboot
COPY --from=tailscale/tailscale:v1.76.6 /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY --from=tailscale/tailscale:v1.76.6 /usr/local/bin/tailscale /usr/local/bin/tailscale

# Install Bun from official image (safer than curl|bash pattern)
ARG BUN_VERSION=1.1.42
COPY --from=oven/bun:1.1.42 /usr/local/bin/bun /usr/local/bin/bun
COPY --from=oven/bun:1.1.42 /usr/local/bin/bunx /usr/local/bin/bunx

# Copy Homebrew from official image (faster than git clone)
COPY --from=homebrew/brew:latest /home/linuxbrew/.linuxbrew /home/node/.linuxbrew
ENV PATH="/home/node/.linuxbrew/bin:/home/node/.linuxbrew/sbin:${PATH}"
ENV HOMEBREW_PREFIX="/home/node/.linuxbrew"
ENV HOMEBREW_CELLAR="/home/node/.linuxbrew/Cellar"
ENV HOMEBREW_REPOSITORY="/home/node/.linuxbrew/Homebrew"

# Optional: install additional apt packages for skills
ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Copy built application from builder (production deps only)
COPY --from=builder /app/dist /app/dist
COPY --from=builder /app/node_modules /app/node_modules
COPY --from=builder /app/package.json /app/package.json

WORKDIR /app
ENV NODE_ENV=production

# Ensure Homebrew, cache, and app directories are owned by node user
RUN mkdir -p /home/node/.cache && chown -R node:node /home/node/.linuxbrew /home/node/.cache /app

# Copy entrypoint script for Tailscale setup
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Expose gateway and bridge ports
EXPOSE 18789 18790

# Health check for gateway mode
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD node -e "const http = require('http'); http.get('http://localhost:18789/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["node", "dist/index.js"]
