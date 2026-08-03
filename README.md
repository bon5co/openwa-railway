# openwa-railway

Wrapper image behind the Railway template for [OpenWA](https://github.com/rmyndharis/OpenWA) —
a self-hosted WhatsApp API gateway (REST + webhooks + dashboard, MIT).

Image: `ghcr.io/bon5co/openwa-railway:latest` — `FROM ghcr.io/rmyndharis/openwa:0.13.0`.

Nothing here forks or patches the application. It bakes in the settings a Railway
deployment needs, for two reasons:

1. Railway's `templateGenerate` drops a template variable's default unless the value is a
   Railway expression, so any literal shipped as a variable publishes as a **blank required
   field** and the deploy form asks the user to type settings the image already knows.
2. Three of the settings are Railway-specific corrections that are wrong by default on this
   platform and cannot be fixed from the deploy form because the deployer does not know to
   look for them.

## What this image changes, and why

### 1. Sessions come back after a redeploy — `AUTO_START_SESSIONS=true`

Upstream defaults this to `false`, which is right for a VPS you deploy once. On Railway every
variable edit, image bump and platform restart replaces the container, and each one silently
leaves every WhatsApp session **stopped**: the API answers 200, the dashboard loads, the health
check passes, and not one message is delivered until a human opens the UI and presses start on
each session. Nothing in the logs says so.

### 2. The session cap is sized to the container — `railway-entrypoint.sh`

`MAX_CONCURRENT_SESSIONS` defaults to `0` (unlimited), and upstream's own comment says a
positive value is what "protects memory/Chromium-constrained deployments". With
`ENGINE_TYPE=whatsapp-web.js` every session drives a full Chromium, so on a memory-capped
container "unlimited" means session N OOM-kills the process and takes every other session with
it — they all share the one container. The entrypoint reads `/sys/fs/cgroup/memory.max` and
budgets ~1 GiB per session with 1.5 GiB reserved, so session N+1 gets an honest `400` instead.
A deployer-set value always wins.

### 3. Rate limiting behind Railway's edge — `TRUSTED_PROXIES` and the real limit knobs

Upstream's `ProxyAwareThrottlerGuard` states the failure mode outright: with no
`TRUSTED_PROXIES` configured it keys the rate-limit bucket on the socket peer, "so all traffic
shares ONE bucket and a single abuser rate-limits everyone (self-DoS)".

On Railway the socket peer is **always the edge, never the caller**. Measured against a live
deployment on 2026-08-03: every request arrives from the CGNAT range `100.64.0.0/10` (observed
`100.64.0.2` through `100.64.0.12`). So the stock limits — **10 requests per second, globally** —
are shared by every client of the deployment, and a bulk send or a busy webhook consumer 429s
itself.

This image sets `TRUSTED_PROXIES=100.64.0.0/10` so the guard reads `X-Forwarded-For` instead of
the socket. That is safe here specifically because Railway **replaces** the inbound header rather
than appending to it — verified by sending `X-Forwarded-For: 203.0.113.9` and watching it get
dropped at the edge — so a caller cannot spoof its way into another bucket.

Bucket separation is still coarser than on a bare VPS: Railway's edge is a CDN77 PoP, so the last
forwarded hop is a per-PoP address rather than a per-client one. The three windows are therefore
also raised to values sized for a whole deployment. They are set under the names the application
actually reads — `RATE_LIMIT_{SHORT,MEDIUM,LONG}_{TTL,LIMIT}`.

### 4. `PORT` is deliberately left alone

Railway injects `PORT` into every service and the injection overrides the image's own `ENV`.
OpenWA honours `$PORT`, so it follows Railway and the template's domain targets the same value.

An earlier revision of this image pinned `PORT` in the entrypoint instead, on the theory that
the entrypoint runs after the injection and therefore wins. It does win — and that is what
breaks the deploy. Measured on 2026-08-03: with the app pinned to `2785` and the domain
targeting `2785`, the public URL served fine while Railway's own HTTP healthcheck failed for the
full five-minute window (`1/1 replicas never became healthy`), because **the healthcheck dials
the injected port, not the domain's target port**. The app was up and answering on 2785 the
whole time. `OPENWA_PORT` remains as an escape hatch off-platform.

### 5. The version is pinned

Upstream's `MAIN_DATABASE_SYNCHRONIZE` defaults to `true`, i.e. TypeORM reshapes the schema from
the entity definitions on boot. Riding `:latest` on an app that auto-migrates in that direction
means an upstream entity change rewrites a deployer's live database with no release note in
between. The tag here moves only when this repo moves.

## Files

- `Dockerfile` — the pinned base plus the baked configuration above.
- `railway-entrypoint.sh` — sizes `MAX_CONCURRENT_SESSIONS`, then execs upstream's
  `docker-entrypoint.sh`. Execing that script (rather than `node`) is required: it is what
  chowns the mounted volume as root before dropping to the `openwa` user via `gosu`, and
  Railway mounts volumes owned by uid 0.
