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

FROM ubuntu-node AS ext-deps
ARG OPENCLAW_EXTENSIONS
COPY extensions /tmp/extensions
RUN mkdir -p /out && \
    for ext in $OPENCLAW_EXTENSIONS; do \
      if [ -f "/tmp/extensions/$ext/package.json" ]; then \
        mkdir -p "/out/$ext" && \
        cp "/tmp/extensions/$ext/package.json" "/out/$ext/package.json"; \
      fi; \
    done

FROM ubuntu-node AS build

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

COPY --from=ext-deps /out/ ./extensions/

RUN pnpm install --frozen-lockfile

COPY . .

# Normalize extension paths so runtime copies preserve safe modes.
RUN for dir in /app/extensions /app/.agent /app/.agents; do \
      if [ -d "$dir" ]; then \
        find "$dir" -type d -exec chmod 755 {} +; \
        find "$dir" -type f -exec chmod 644 {} +; \
      fi; \
    done

# Stub A2UI bundle on cross-arch builds where vendor tooling is unavailable.
RUN pnpm canvas:a2ui:bundle || \
    (echo "A2UI bundle: creating stub (non-fatal)" && \
     mkdir -p src/canvas-host/a2ui && \
     echo "/* A2UI bundle unavailable in this build */" > src/canvas-host/a2ui/a2ui.bundle.js && \
     echo "stub" > src/canvas-host/a2ui/.bundle.hash && \
     rm -rf vendor/a2ui apps/shared/OpenClawKit/Tools/CanvasA2UI)
RUN pnpm build:docker

# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

FROM build AS runtime-assets
RUN CI=true pnpm prune --prod && \
    pnpm store prune && \
    find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete && \
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

COPY --from=runtime-assets --chown=node:node /app/dist ./dist
COPY --from=runtime-assets --chown=node:node /app/node_modules ./node_modules
COPY --from=runtime-assets --chown=node:node /app/package.json .
COPY --from=runtime-assets --chown=node:node /app/openclaw.mjs .
COPY --from=runtime-assets --chown=node:node /app/extensions ./extensions
COPY --from=runtime-assets --chown=node:node /app/skills ./skills
COPY --from=runtime-assets --chown=node:node /app/docs ./docs

# Keep pnpm available for container-local workflows under the non-root user.
ENV COREPACK_HOME=/usr/local/share/corepack
RUN install -d -m 0755 "$COREPACK_HOME" && \
    corepack enable && \
    for attempt in 1 2 3 4 5; do \
      if corepack prepare "$(node -p "require('./package.json').packageManager")" --activate; then \
        break; \
      fi; \
      if [ "$attempt" -eq 5 ]; then \
        exit 1; \
      fi; \
      sleep $((attempt * 2)); \
    done && \
    chmod -R a+rX "$COREPACK_HOME"

# Install browsers into the runtime image so OPENCLAW_INSTALL_BROWSER persists.
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      mkdir -p /home/node/.cache/ms-playwright && \
      PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      chown -R node:node /home/node/.cache/ms-playwright && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Optionally install Docker CLI for sandbox container management.
ARG OPENCLAW_INSTALL_DOCKER_CLI=""
ARG OPENCLAW_DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
RUN if [ -n "$OPENCLAW_INSTALL_DOCKER_CLI" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg && \
      install -m 0755 -d /etc/apt/keyrings && \
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg.asc && \
      expected_fingerprint="$(printf '%s' "$OPENCLAW_DOCKER_GPG_FINGERPRINT" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')" && \
      actual_fingerprint="$(gpg --batch --show-keys --with-colons /tmp/docker.gpg.asc | awk -F: '$1 == "fpr" { print toupper($10); exit }')" && \
      if [ -z "$actual_fingerprint" ] || [ "$actual_fingerprint" != "$expected_fingerprint" ]; then \
        echo "ERROR: Docker apt key fingerprint mismatch (expected $expected_fingerprint, got ${actual_fingerprint:-<empty>})" >&2; \
        exit 1; \
      fi && \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg.asc && \
      rm -f /tmp/docker.gpg.asc && \
      chmod a+r /etc/apt/keyrings/docker.gpg && \
      . /etc/os-release && \
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list && \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        docker-ce-cli docker-compose-plugin && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

# Expose CLI on PATH for interactive shells inside containers/pods.
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw && \
    chmod 755 /app/openclaw.mjs

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
