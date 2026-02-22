FROM ubuntu:24.04 AS ubuntu-node

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      emacs-nox \
      git \
      gnupg \
      htop \
      openssl \
      openssh-client \
      python3 \
      vim \
      ${OPENCLAW_DOCKER_APT_PACKAGES} && \
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    corepack enable && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

FROM ubuntu-node AS builder

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      python3 \
      unzip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~300MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY . .
RUN pnpm build

# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# Keep only runtime dependencies and clear package-manager caches.
RUN CI=true pnpm prune --prod && \
    pnpm store prune && \
    rm -rf /root/.local/share/pnpm/store /root/.npm /root/.cache /root/.bun/install/cache

FROM ubuntu-node

WORKDIR /app

ENV NODE_ENV=production

# Allow non-root user to write temp files during runtime/tests.
RUN set -eux; \
    if getent group node >/dev/null 2>&1; then \
      groupmod --gid 1001 node; \
    elif getent group 1001 >/dev/null 2>&1; then \
      echo "GID 1001 is already in use by another group; cannot create node group" >&2; \
      exit 1; \
    else \
      groupadd --gid 1001 node; \
    fi; \
    if id -u node >/dev/null 2>&1; then \
      usermod --uid 1001 --gid 1001 --home /home/node --shell /bin/bash node; \
    elif getent passwd 1001 >/dev/null 2>&1; then \
      echo "UID 1001 is already in use by another user; cannot create node user" >&2; \
      exit 1; \
    else \
      useradd --uid 1001 --gid 1001 --create-home --home-dir /home/node --shell /bin/bash node; \
    fi; \
    mkdir -p /home/node /app; \
    chown -R node:node /home/node /app
ENV HOME=/home/node

COPY --from=builder --chown=node:node /app /app

# Expose CLI on PATH for interactive shells inside containers/pods.
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw

RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-${ARCH}.tgz" | \
    tar -xzf - -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/aliyun

# Security hardening: Run as non-root user.
USER node

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
