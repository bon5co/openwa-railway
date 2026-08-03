# OpenWA, packaged for Railway.
#
# Thin wrapper over the official upstream image. Everything here is either a literal
# that Railway's template pipeline would otherwise publish as a BLANK REQUIRED field,
# or a Railway-specific correction measured against a live deployment.
FROM ghcr.io/rmyndharis/openwa:0.13.0

# ---------------------------------------------------------------------------
# Storage. Every path lives under /app/data, which is the volume mount point.
# Upstream's docker-entrypoint.sh chowns /app/data to the openwa user at every
# container start before gosu-dropping, which is what makes Railway's root-owned
# volume mount work on first boot — so this image keeps that ENTRYPOINT chain
# intact (see railway-entrypoint.sh, which execs it).
# ---------------------------------------------------------------------------
ENV DATABASE_TYPE=sqlite \
    DATABASE_NAME=/app/data/openwa.sqlite \
    SESSION_DATA_PATH=/app/data/sessions \
    STORAGE_TYPE=local \
    STORAGE_LOCAL_PATH=/app/data/media \
    PLUGINS_DIR=/app/data/plugins \
    BOOTSTRAP_KEY_FILE=/app/data/.api-key \
    BAILEYS_AUTH_DIR=/app/data/baileys

# ---------------------------------------------------------------------------
# Engine. whatsapp-web.js drives a real Chromium per session; the flags below are
# the container-safe set (no sandbox, no /dev/shm dependency — Railway gives a
# container the default 64 MB /dev/shm, and Chromium deadlocks on it without
# --disable-dev-shm-usage).
# ---------------------------------------------------------------------------
ENV NODE_ENV=production \
    ENGINE_TYPE=whatsapp-web.js \
    LOG_LEVEL=info \
    PUPPETEER_HEADLESS=true \
    PUPPETEER_ARGS="--no-sandbox,--disable-setuid-sandbox,--disable-dev-shm-usage,--disable-gpu"

# ---------------------------------------------------------------------------
# Sessions survive a redeploy.
#
# Upstream defaults AUTO_START_SESSIONS to false. On a VPS that is a sane default —
# you deploy once. On Railway every variable edit, every image bump and every
# platform-side restart replaces the container, and each of those silently leaves
# every WhatsApp session STOPPED: the API answers 200, the dashboard loads, the
# health check passes, and no message is ever delivered again until a human opens
# the UI and presses start on each session. Turning it on is the whole point of
# running this on a redeploy-driven platform.
# ---------------------------------------------------------------------------
ENV AUTO_START_SESSIONS=true

# ---------------------------------------------------------------------------
# Rate limiting behind Railway's edge.
#
# Upstream's ProxyAwareThrottlerGuard says it outright: with no TRUSTED_PROXIES
# configured it keys the rate-limit bucket on the socket peer, "so all traffic
# shares ONE bucket and a single abuser rate-limits everyone (self-DoS)". On
# Railway the socket peer is ALWAYS the edge, never the caller — measured against
# a live deployment on 2026-08-03, the peer address is drawn from the CGNAT range
# 100.64.0.0/10 (observed 100.64.0.2 through .12) for every single request.
#
# So the default limits — 10 requests per SECOND, globally — are shared by every
# client of the deployment. A bulk send or a busy webhook consumer 429s itself.
#
# Two corrections, both measured:
#   1. TRUSTED_PROXIES=100.64.0.0/10 lets the guard read X-Forwarded-For instead
#      of the socket. This is safe here specifically because Railway REPLACES the
#      inbound XFF rather than appending to it — verified by sending
#      "X-Forwarded-For: 203.0.113.9" and observing it dropped at the edge — so a
#      caller cannot spoof its way into another bucket.
#   2. The three windows are sized for a whole deployment rather than for one
#      caller. Railway's edge is a CDN77 PoP, so the last forwarded hop is a
#      per-PoP address, not a per-client one; bucket separation is therefore
#      coarser than on a bare VPS no matter what is configured, and the limits
#      have to absorb that. These are the real knob names — the app reads
#      RATE_LIMIT_{SHORT,MEDIUM,LONG}_{TTL,LIMIT} and nothing else.
# ---------------------------------------------------------------------------
ENV TRUSTED_PROXIES=100.64.0.0/10 \
    RATE_LIMIT_SHORT_TTL=1000 \
    RATE_LIMIT_SHORT_LIMIT=100 \
    RATE_LIMIT_MEDIUM_TTL=60000 \
    RATE_LIMIT_MEDIUM_LIMIT=2000 \
    RATE_LIMIT_LONG_TTL=3600000 \
    RATE_LIMIT_LONG_LIMIT=50000

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

EXPOSE 2785

# dumb-init stays PID 1, exactly as upstream. railway-entrypoint.sh sizes the
# session cap to the container and then execs upstream's docker-entrypoint.sh,
# which is what chowns the volume and drops to the openwa user via gosu.
ENTRYPOINT ["dumb-init", "--", "/usr/local/bin/railway-entrypoint.sh"]
CMD ["node", "dist/main"]
