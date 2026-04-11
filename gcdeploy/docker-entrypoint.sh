#!/bin/sh
# apicity-gc entrypoint. Runs every container boot.
#
# On first boot: clones apicity into /gt/apicity, bakes city.toml into
# /gt/city, writes /gt/apicity/.env from kamal-injected env vars, registers
# the rig, and performs the one-shot supervisor registration dance. On
# subsequent boots: pulls main, refreshes .env, and exec's the CMD.
#
# The CMD is `gc supervisor run` (set in the Dockerfile), which runs as PID 1
# under tini for the lifetime of the container. `gc dashboard serve` is
# launched in the background from this script before the exec.

set -eu

# ── 1. GitHub App auth (apicity is public, but endpoint-builder pushes PRs
# via `gh pr create`, which needs bot identity credentials). ────────────
if [ -n "${GH_APP_PEM:-}" ]; then
    GH_APP_PEM_FILE="/gt/.github-app.pem"
    printf '%s' "$GH_APP_PEM" | base64 -d > "$GH_APP_PEM_FILE"
    chmod 600 "$GH_APP_PEM_FILE"
    export GH_APP_PEM_FILE

    gh_app_refresh() {
        TOKEN=$(/app/scripts/gh-app-token.sh) || return 1
        printf '%s\n' "$TOKEN" | gh auth login --with-token 2>/dev/null
        git config --global credential.helper store
        printf 'https://x-access-token:%s@github.com\n' "$TOKEN" > ~/.git-credentials
        echo "entrypoint: GitHub App token refreshed ($(date +%H:%M:%S))"
    }

    mkdir -p /gt/.config/gh ~/.config
    ln -sfn /gt/.config/gh ~/.config/gh

    gh_app_refresh

    # Background refresh loop (App installation tokens last ~1h).
    ( while true; do sleep 3000; gh_app_refresh || true; done ) &
fi

# ── 2. Git / dolt identity ──────────────────────────────────────────────
if [ -n "${GIT_USER:-}" ] && [ -n "${GIT_EMAIL:-}" ]; then
    git config --global user.name  "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"
    git config --global credential.helper store
    dolt config --global --add user.name  "$GIT_USER" 2>/dev/null || true
    dolt config --global --add user.email "$GIT_EMAIL" 2>/dev/null || true
fi

# ── 3. Seed the city directory on first boot. Do NOT use `gc init` ──────
# (it tries to install a launchd/systemd service, which fails in a container).
if [ ! -f /gt/city/city.toml ]; then
    echo "entrypoint: seeding /gt/city from baked city.toml"
    mkdir -p /gt/city
    cp /app/city.toml.baked /gt/city/city.toml
fi

# ── 4. Clone apicity on first boot, pull on subsequent ──────────────────
if [ ! -d /gt/apicity/.git ]; then
    echo "entrypoint: cloning apicity into /gt/apicity"
    git clone https://github.com/justintanner/apicity.git /gt/apicity
else
    echo "entrypoint: refreshing /gt/apicity from origin/main"
    git -C /gt/apicity fetch origin main
    git -C /gt/apicity reset --hard origin/main
fi

# ── 5. Install apicity deps in the background (non-blocking) ────────────
# The dashboard healthcheck has a 180s start_period to absorb this; the
# pack's session_setup on endpoint-builder also runs `pnpm install
# --frozen-lockfile` at wake time and will see a hot cache.
( cd /gt/apicity && pnpm install --frozen-lockfile ) &

# ── 6. Write /gt/apicity/.env from resolved secrets ─────────────────────
# Replaces `op run` for the server (no op CLI in the container). These are
# the 13 keys apicity's .env.tpl enumerates — see ~/apicity/.env.tpl.
{
    for KEY in \
        OPENAI_API_KEY \
        KIE_API_KEY \
        XAI_API_KEY \
        XAI_MANAGEMENT_API_KEY \
        KIMI_CODING_API_KEY \
        FAL_API_KEY \
        FIREWORKS_API_KEY \
        FIREWORKS_ACCOUNT_ID \
        GEMINI_API_KEY \
        ANTHROPIC_API_KEY \
        DASHSCOPE_API_KEY \
        DASHBOARD_USER \
        DASHBOARD_PASS; do
        eval "VAL=\${$KEY:-}"
        if [ -n "$VAL" ]; then
            printf '%s=%s\n' "$KEY" "$VAL"
        fi
    done
} > /gt/apicity/.env
chmod 600 /gt/apicity/.env

# ── 7. Export GC_SERVER=1 for the pack's scripts to bypass `op` ─────────
export GC_SERVER=1

# ── 8. Register the rig on first boot (idempotent gate via .beads/) ─────
# `gc rig add` has no --adopt flag in 0.13.4; gate on .beads/ existence.
if [ ! -d /gt/apicity/.beads ]; then
    echo "entrypoint: registering apicity rig"
    ( cd /gt/city && gc rig add /gt/apicity --include /gt/apicity/gc/pack )
fi

# ── 9. First-boot supervisor registration dance ─────────────────────────
# The supervisor reads ~/.gc/cities.toml. `gc register` is idempotent but
# requires a running supervisor. On first boot we start one in the
# background, register, then stop it. The exec below picks up the registered
# city when it becomes PID 1.
#
# NOTE: `gc supervisor start` may rely on launchd/systemd which aren't
# available in a container. If it fails, fall back to writing
# ~/.gc/cities.toml directly with the minimal registration format (see
# gcdeploy/README.md "Recovery" for the byte pattern).
if [ ! -f /gt/.gc-registered ]; then
    echo "entrypoint: one-shot supervisor registration"
    if gc supervisor start 2>/dev/null; then
        sleep 2
        gc register /gt/city || echo "entrypoint: gc register failed, continuing anyway" >&2
        gc supervisor stop 2>/dev/null || true
    else
        echo "entrypoint: gc supervisor start unavailable (no launchd/systemd in container)" >&2
        echo "entrypoint: writing ~/.gc/cities.toml directly as fallback" >&2
        mkdir -p /home/agent/.gc
        cat > /home/agent/.gc/cities.toml <<'CITIES'
[[cities]]
name = "apicity"
path = "/gt/city"
CITIES
    fi
    touch /gt/.gc-registered
fi

# ── 10. Start the dashboard in the background ──────────────────────────
# Binds :8080 for external traffic, connects to the supervisor API (loopback
# 127.0.0.1:8372) that `gc supervisor run` will open when it starts below.
# The supervisor normally creates /gt/city/.gc on startup; ensure it exists
# first so the redirect doesn't fail during the race between dashboard and
# supervisor start.
mkdir -p /gt/city/.gc
gc dashboard serve \
    --port 8080 \
    --api http://127.0.0.1:8372 \
    --city /gt/city \
    >/gt/city/.gc/dashboard.log 2>&1 &

# ── 11. Exec the CMD — `gc supervisor run` becomes PID 1 under tini ─────
exec "$@"
