# apicity-gc — Gas City (gc) runtime image managing the apicity monorepo.
#
# Forks the gastown Dockerfile but drops the gt build and installs the gc
# binary from the Gas City Homebrew release tarball. The container runs
# `gc supervisor run` as PID 1 under tini, alongside `gc dashboard serve`
# (launched by docker-entrypoint.sh) on :8080.
#
# Build from the ~/gastown repo root:
#   docker build -t apicity-gc:latest -f gcdeploy/Dockerfile .
# or via kamal from ~/gastown/gcdeploy/:
#   kamal build push

FROM docker/sandbox-templates:claude-code

ARG GC_VERSION=0.13.4
ARG PNPM_VERSION=10.30.3

USER root

# System dependencies gc needs + the ones the apicity dev loop exercises.
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    gh \
    git \
    jq \
    libicu-dev \
    netcat-openbsd \
    ripgrep \
    sqlite3 \
    tini \
    tmux \
    util-linux \
    vim \
    zsh \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# pnpm via corepack (base image ships node). Match apicity's package.json
# packageManager field so `pnpm install --frozen-lockfile` replays cleanly.
RUN corepack enable && corepack prepare pnpm@${PNPM_VERSION} --activate

# Install Go — only needed to build `bd` (beads CLI) from source because
# the prebuilt binaries link against ICU 74 but the base image ships ICU 76.
ARG GO_VERSION=1.25.6
RUN ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:/home/agent/go/bin:/home/agent/bin:${PATH}"

# Beads (bd) — gc's default task store. Build from source per ICU workaround.
RUN GOBIN=/usr/local/bin CGO_ENABLED=1 go install github.com/steveyegge/beads/cmd/bd@latest \
    && go clean -cache -modcache

# Dolt — gc's default beads data plane.
RUN curl -fsSL https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash

# Gas City (gc) binary from the gastownhall GitHub release.
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
        amd64) GC_ARCH=amd64 ;; \
        arm64) GC_ARCH=arm64 ;; \
        *) echo "unsupported arch $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/gastownhall/gascity/releases/download/v${GC_VERSION}/gascity_${GC_VERSION}_linux_${GC_ARCH}.tar.gz" \
        | tar -C /tmp -xz && \
    install -m 755 /tmp/gc /usr/local/bin/gc && \
    rm -rf /tmp/gc

# Working directory + ownership.
RUN mkdir -p /app /gt /home/agent/.gc && chown -R agent:agent /app /gt /home/agent/.gc

# Bash/zsh env defaults.
RUN echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/profile.d/gc.sh && \
    echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/zsh/zshenv && \
    echo 'export COLORTERM="truecolor"' >> /etc/profile.d/colorterm.sh && \
    echo 'export COLORTERM="truecolor"' >> /etc/zsh/zshenv && \
    echo 'export TERM="xterm-256color"' >> /etc/profile.d/term.sh && \
    echo 'export TERM="xterm-256color"' >> /etc/zsh/zshenv

USER agent

# Copy only the gcdeploy staging tree so the image doesn't carry the gt
# source. Paths are relative to the build context (the ~/gastown repo root).
COPY --chown=agent:agent gcdeploy/city.toml          /app/city.toml.baked
COPY --chown=agent:agent gcdeploy/docker-entrypoint.sh /app/docker-entrypoint.sh
COPY --chown=agent:agent gcdeploy/scripts/gh-app-token.sh /app/scripts/gh-app-token.sh

WORKDIR /gt/city

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=5s --start-period=180s --retries=3 \
  CMD curl -fsS http://localhost:8080/up || exit 1

ENTRYPOINT ["tini", "--", "/app/docker-entrypoint.sh"]
CMD ["gc", "supervisor", "run"]
