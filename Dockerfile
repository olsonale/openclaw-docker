FROM node:22-bookworm

# OCI Image Labels
LABEL org.opencontainers.image.title="OpenClaw Docker"
LABEL org.opencontainers.image.description="Docker setup for OpenClaw - AI-powered coding assistant"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.source="https://github.com/openclaw/openclaw"

# Expose gateway and bridge ports
EXPOSE 18789 18790

# Install build-essential and gosu for privilege dropping
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    gosu \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Install Tailscale (pinned version) and copy containerboot from official image
ARG TAILSCALE_VERSION=1.76.6
COPY --from=tailscale/tailscale:v1.76.6 /usr/local/bin/containerboot /usr/local/bin/containerboot
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null && \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list && \
    apt-get update && \
    apt-get install -y tailscale=${TAILSCALE_VERSION} && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Homebrew via git (for skills) - pinned to specific release for reproducibility
ARG HOMEBREW_VERSION=4.4.8
RUN git clone --depth 1 --branch ${HOMEBREW_VERSION} https://github.com/Homebrew/brew /home/node/.homebrew
ENV PATH="/home/node/.homebrew/bin:/home/node/.homebrew/sbin:${PATH}"
ENV HOMEBREW_PREFIX="/home/node/.homebrew"
ENV HOMEBREW_CELLAR="/home/node/.homebrew/Cellar"
ENV HOMEBREW_REPOSITORY="/home/node/.homebrew"

# Install Bun from official image (safer than curl|bash pattern)
ARG BUN_VERSION=1.1.42
COPY --from=oven/bun:1.1.42 /usr/local/bin/bun /usr/local/bin/bun
COPY --from=oven/bun:1.1.42 /usr/local/bin/bunx /usr/local/bin/bunx

RUN corepack enable

# Clone OpenClaw source from upstream
ARG OPENCLAW_VERSION=main
RUN git clone --depth 1 --branch ${OPENCLAW_VERSION} \
    https://github.com/openclaw/openclaw /app

WORKDIR /app

# Optional: install additional apt packages for skills
ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

RUN pnpm install --frozen-lockfile

RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
# Force pnpm for UI build (Bun may fail on some ARM architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Ensure Homebrew, cache, and app directories are owned by node user
RUN mkdir -p /home/node/.cache && chown -R node:node /home/node/.homebrew /home/node/.cache /app

# Copy entrypoint script for Tailscale setup
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Health check for gateway mode
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD node -e "const http = require('http'); http.get('http://localhost:18789/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["node", "dist/index.js"]
