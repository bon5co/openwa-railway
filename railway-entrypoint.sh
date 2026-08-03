#!/bin/sh
# Railway shim for OpenWA.
#
# Sizes the concurrent-session cap to the container's real memory limit, then hands
# over to upstream's own entrypoint. It must exec docker-entrypoint.sh and not
# `node` directly: that script is what chowns the mounted volume as root and then
# drops to the openwa user via gosu, so skipping it breaks first boot on a Railway
# volume (which is mounted uid 0).
set -e

# ---------------------------------------------------------------------------
# PORT
#
# Railway injects PORT into every service and that injection OVERRIDES the image's
# own ENV, so an image that honours $PORT (this one does — src/main.ts falls back to
# 2785 only when PORT is unset) listens on Railway's 8080 while the template's domain
# points somewhere else. Measured on a live deployment 2026-08-03: the app logged
# "OpenWA is running on: http://localhost:8080" against a domain whose target port was
# 2785, i.e. a clean 502 at the edge with a container that looks perfectly healthy from
# the inside.
#
# The entrypoint runs AFTER the injection, so it is the only place that can win. Pin
# the listen port to the same value the published template's domain targets. A deployer
# who wants a different port sets OPENWA_PORT and repoints the domain to match.
# ---------------------------------------------------------------------------
PORT="${OPENWA_PORT:-2785}"
export PORT
echo "[railway] listening on PORT=${PORT}"

# ---------------------------------------------------------------------------
# MAX_CONCURRENT_SESSIONS
#
# Upstream defaults it to 0, which means UNLIMITED, and its own comment notes that
# a positive value is what "protects memory/Chromium-constrained deployments".
# With ENGINE_TYPE=whatsapp-web.js each session drives a full Chromium, so on a
# container with a fixed memory limit "unlimited" means the Nth session OOM-kills
# the process — taking every other session down with it, because they all live in
# the one container. The cap turns that into an honest 400 on session N+1.
#
# Deployer-set values win; this only fills in a default.
# ---------------------------------------------------------------------------
if [ -z "${MAX_CONCURRENT_SESSIONS}" ] || [ "${MAX_CONCURRENT_SESSIONS}" = "0" ]; then
    mem_bytes=""

    # cgroup v2 (what Railway runs). "max" means unconstrained.
    if [ -r /sys/fs/cgroup/memory.max ]; then
        read -r v < /sys/fs/cgroup/memory.max || v=""
        case "$v" in
            ''|max|*[!0-9]*) ;;
            *) mem_bytes="$v" ;;
        esac
    fi

    # cgroup v1 fallback. Unconstrained shows as a huge sentinel value.
    if [ -z "$mem_bytes" ] && [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        read -r v < /sys/fs/cgroup/memory/memory.limit_in_bytes || v=""
        case "$v" in
            ''|*[!0-9]*) ;;
            *) [ "$v" -lt 4000000000000 ] && mem_bytes="$v" ;;
        esac
    fi

    if [ -n "$mem_bytes" ]; then
        mem_mib=$((mem_bytes / 1048576))
        # ~1 GiB per Chromium session, 1.5 GiB reserved for node + SQLite + the
        # bundled dashboard. Floor of 1 so a small container still runs one session.
        sessions=$(((mem_mib - 1536) / 1024))
        [ "$sessions" -lt 1 ] && sessions=1
        [ "$sessions" -gt 24 ] && sessions=24
        MAX_CONCURRENT_SESSIONS="$sessions"
        export MAX_CONCURRENT_SESSIONS
        echo "[railway] container memory ${mem_mib} MiB -> MAX_CONCURRENT_SESSIONS=${MAX_CONCURRENT_SESSIONS}"
    else
        echo "[railway] no cgroup memory limit found; leaving MAX_CONCURRENT_SESSIONS unset (unlimited)"
    fi
else
    echo "[railway] MAX_CONCURRENT_SESSIONS=${MAX_CONCURRENT_SESSIONS} (set by deployer)"
fi

echo "[railway] AUTO_START_SESSIONS=${AUTO_START_SESSIONS:-false} TRUSTED_PROXIES=${TRUSTED_PROXIES:-<unset>}"

exec /usr/local/bin/docker-entrypoint.sh "$@"
