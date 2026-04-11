# apicity-gc — Kamal deploy staging

Gas City (`gc`) runtime image that manages the [apicity](https://github.com/justintanner/apicity) monorepo. Deploys alongside the existing gastown (`gt`) container on the same host (`65.21.88.38`) under a new subdomain (`apicity.superlzy.com`).

## What ships

- **Image**: `justintanner/apicity-gc:latest` — built from `Dockerfile` in this directory with `gcdeploy/` as the build context root relative.
- **Runtime**: `gc supervisor run` as PID 1 + `gc dashboard serve` on `:8080` (started by `docker-entrypoint.sh`).
- **Rig**: `apicity` at `/gt/apicity` (cloned from `github.com/justintanner/apicity` on first boot).
- **Pack**: `/gt/apicity/gc/pack` — 3 agents (`endpoint-builder`, `preflight-sentinel`, `har-auditor`), 3 formulas, 2 orders. See `~/apicity/CLAUDE.md` for the full spec.
- **Volume**: `gc-workspace:/gt` — persistent; holds the apicity clone, `.beads/`, city state, worktrees.
- **Secrets**: 13 keys + `GH_APP_PEM`, all resolved from the `Apicity` 1Password vault at `kamal deploy` time.

## Deploy

```sh
eval $(op signin)                 # kamal needs op for secrets resolution
cd ~/gastown/gcdeploy
kamal build push                  # first deploy only, or after Dockerfile changes
kamal deploy                      # idempotent; safe to re-run
```

## Inspect

```sh
kamal status                      # container state
kamal logs                        # dashboard log tail
kamal shell                       # interactive bash
kamal status --primary            # pool/health

# Aliases defined in config/deploy.yml:
kamal status                      # gc status
kamal rigs                        # gc rig list
kamal formulas                    # gc formula list
kamal orders                      # gc order list
kamal config                      # gc config show  (expect 3 agents + 2 orders, zero warnings)
```

## Seed the first endpoint bead

```sh
kamal shell
  cd /gt/city
  bd create "Add openai POST /v1/embeddings" \
    --metadata gc.routed_to=endpoint-builder
  gc hook                         # endpoint-builder picks it up at next reconciliation
  gc session attach endpoint-builder   # watch it walk the formula
  exit
```

## Recovery — wipe the volume

If the container is wedged (bad beads state, stale clone, corrupted worktree), nuke the volume and redeploy:

```sh
kamal app stop
ssh deploy@65.21.88.38 'docker volume rm apicity-gc_gc-workspace'
kamal deploy
```

## Fallback: if `gc supervisor start` is unavailable in the container

The entrypoint's first-boot registration dance calls `gc supervisor start` to bring the supervisor up briefly so `gc register` can succeed. That command relies on launchd (macOS) or systemd-user (Linux) and may fail in a minimal container. The entrypoint catches that failure and writes `~/.gc/cities.toml` directly as a fallback:

```toml
[[cities]]
name = "apicity"
path = "/gt/city"
```

If the PID-1 supervisor rejects that format (format may evolve across gc releases), run `gc register /gt/city` once manually via `kamal shell` after the first boot:

```sh
kamal shell
  gc supervisor status              # should already be running (it's PID 1)
  gc register /gt/city              # idempotent
  exit
```

## What this does NOT touch

- `~/gastown/config/deploy.yml` — the existing `gt`-based gastown deploy is untouched. Both deploys coexist on the same box with different services, images, volumes, and proxy hostnames.
- `~/gastown/docker-entrypoint.sh` — that's the gt entrypoint with nakedapi wiring. Ignored by this deploy.
- `~/gastown/Dockerfile` — that's the gt image. Ignored.

## Open verification items (first deploy)

These are resolvable only by actually booting the container once:

1. **`gc supervisor start` in-container behavior** — may need the `cities.toml` fallback to kick in. See above.
2. **`pnpm install` timing** — first boot blocks on deps for ~60–120s in the background. Dashboard `:8080` should come up in under 5s. Healthcheck `start_period = 180s` absorbs both.
3. **`gc dashboard` + `gc supervisor run` concurrency** — two processes inside tini. If tini kills one on the other's exit, we may need an explicit process supervisor (s6-overlay). Watch `kamal logs` on first deploy.
4. **`gh pr create` from inside a worktree** — the bot identity is set globally via `GH_APP_PEM`; verify from `kamal shell` that `gh auth status` reports the bot account before the first endpoint bead lands.
