#!/usr/bin/env bash
# HIS Add-on entrypoint
# Modes:
#   WIZARD  — .env missing → start orchestrator wizard on port 8099, wait for /tmp/his_stack_ready
#   PROXY   — .env exists  → stack is running, nginx proxies HA ingress → his_gateway:8000

set -euo pipefail

HIS_DIR="/share/his"
ENV_FILE="${HIS_DIR}/repo/.env"
READY_FLAG="/tmp/his_stack_ready"
COMPOSE_FILE="${HIS_DIR}/repo/docker-compose.yml"
COMPOSE_ADDON="${HIS_DIR}/repo/ha-addon/docker-compose.addon.yml"

log() { echo "[HIS] $*"; }

# ── Graceful shutdown ─────────────────────────────────────────────────────────
# Trap SIGTERM (sent by HA Supervisor on stop/restart) and SIGINT (Ctrl-C).
# Brings down all managed containers cleanly before exiting.

shutdown() {
    log "Shutting down HIS stack…"
    if [ -f "${COMPOSE_FILE}" ] && [ -f "${ENV_FILE}" ]; then
        docker compose \
            -f "${COMPOSE_FILE}" \
            -f "${COMPOSE_ADDON}" \
            --env-file "${ENV_FILE}" \
            down --timeout 30 2>&1 | tail -10 || true
    fi
    nginx -s quit 2>/dev/null || true
    log "HIS stopped."
    exit 0
}

trap shutdown SIGTERM SIGINT

# ── Docker helpers ────────────────────────────────────────────────────────────

compose_up() {
    docker compose \
        -f "${COMPOSE_FILE}" \
        -f "${COMPOSE_ADDON}" \
        --env-file "${ENV_FILE}" \
        up -d --remove-orphans "$@"
}

compose_ps() {
    docker compose \
        -f "${COMPOSE_FILE}" \
        -f "${COMPOSE_ADDON}" \
        --env-file "${ENV_FILE}" \
        ps --quiet 2>/dev/null
}

join_his_net() {
    # Connect this add-on container to his_net so nginx can reach his_gateway.
    # HOSTNAME is set by Docker to the container ID.
    local net="his_his_net"   # compose project "his" + network name "his_net"
    docker network connect "${net}" "${HOSTNAME}" 2>/dev/null \
        && log "Joined ${net}" \
        || log "Already in ${net} (or connect failed — nginx may fall back to host network)"
}

# ── nginx ─────────────────────────────────────────────────────────────────────

start_nginx() {
    log "Starting nginx on :8099…"
    nginx -g "daemon off;" &
    NGINX_PID=$!
}

# ── Wizard mode ───────────────────────────────────────────────────────────────

run_wizard() {
    log "No .env found — starting Setup Wizard on :8099"

    uvicorn main:app \
        --app-dir /orchestrator \
        --host 0.0.0.0 \
        --port 8099 \
        --log-level info &
    WIZARD_PID=$!

    log "Wizard running. Open HIS in the HA sidebar to configure."

    # Wait for the ready flag (written by orchestrator /deploy SSE endpoint)
    while [ ! -f "${READY_FLAG}" ]; do
        sleep 2
    done

    log "Stack ready — handing off to proxy mode."
    kill "${WIZARD_PID}" 2>/dev/null || true
    wait "${WIZARD_PID}" 2>/dev/null || true
}

# ── Proxy mode ────────────────────────────────────────────────────────────────

run_proxy() {
    log "Proxy mode — forwarding HA ingress → his_gateway:8000"

    if [ -f "${COMPOSE_FILE}" ]; then
        log "Ensuring HIS stack is up…"
        compose_up 2>&1 | tail -10 || true
    fi

    join_his_net
    start_nginx

    # Watchdog: restart stack if containers go missing; exit if uninstall was triggered
    while true; do
        sleep 60 &
        wait $!
        # Uninstall wipes /share/his and touches this flag — exit so HA can remove the add-on
        if [ -f "/tmp/his_uninstalled" ]; then
            log "Uninstall complete — exiting."
            nginx -s quit 2>/dev/null || true
            exit 0
        fi
        if [ -f "${COMPOSE_FILE}" ]; then
            if ! compose_ps | grep -q .; then
                log "⚠ HIS stack appears stopped — restarting…"
                compose_up 2>&1 | tail -5 || true
                join_his_net
            fi
        fi
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

mkdir -p "${HIS_DIR}"

# Clear transient flags from previous runs (they live in /tmp which persists
# across container stop/start within the same container lifecycle).
rm -f "${READY_FLAG}" /tmp/his_uninstalled

# Enter wizard mode if:
#   - .env doesn't exist, OR
#   - the HIS stack has never been deployed (no docker-compose.yml in repo)
if [ ! -f "${ENV_FILE}" ] || [ ! -f "${COMPOSE_FILE}" ]; then
    run_wizard
fi

run_proxy
