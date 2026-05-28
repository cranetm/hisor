#!/usr/bin/env bash
# HIS Add-on entrypoint

HIS_DIR="/share/his"
ENV_FILE="${HIS_DIR}/repo/.env"
READY_FLAG="/tmp/his_stack_ready"
COMPOSE_FILE="${HIS_DIR}/repo/docker-compose.yml"
COMPOSE_ADDON="${HIS_DIR}/repo/ha-addon/docker-compose.addon.yml"
COMMIT_FILE="${HIS_DIR}/.last_deployed_commit"

log() { echo "[HIS] $*"; }

# ── Graceful shutdown ─────────────────────────────────────────────────────────
# Trap SIGTERM (sent by HA Supervisor on stop/restart) and SIGINT (Ctrl-C).
# Brings down all managed containers cleanly before exiting.

shutdown() {
    log "Shutting down HIS stack…"
    if [ -f "${COMPOSE_FILE}" ] && [ -f "${ENV_FILE}" ]; then
        docker compose \
            --project-name his \
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
        --project-name his \
        -f "${COMPOSE_FILE}" \
        -f "${COMPOSE_ADDON}" \
        --env-file "${ENV_FILE}" \
        up -d --remove-orphans "$@"
}

compose_ps() {
    docker compose \
        --project-name his \
        -f "${COMPOSE_FILE}" \
        -f "${COMPOSE_ADDON}" \
        --env-file "${ENV_FILE}" \
        ps --quiet 2>/dev/null
}

join_his_net() {
    local net="his_his_net"
    local cid
    # cgroupv2 (HA OS) doesn't embed the container ID in /proc/self/cgroup.
    # Find our own container by matching the addon name pattern (*_his).
    cid=$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null \
        | grep '[[:space:]]addon_.*_his$' | awk '{print $1}' | head -1) || true
    if [ -z "${cid}" ]; then
        log "⚠ Could not determine addon container ID — skipping network join"
        return 0
    fi
    # Retry until connected so nginx can resolve his_gateway DNS immediately.
    local i=0
    while [ $i -lt 15 ]; do
        if docker network connect "${net}" "${cid}" 2>/dev/null; then
            log "Joined ${net} (${cid:0:12})"
            return 0
        fi
        # Check if already connected (connect returns non-zero in that case too)
        if docker network inspect "${net}" --format '{{range .Containers}}{{.ID}} {{end}}' 2>/dev/null \
                | grep -q "${cid}"; then
            log "Already in ${net} (${cid:0:12})"
            return 0
        fi
        i=$((i+1))
        sleep 2
    done
    log "⚠ Could not join ${net} after retries"
    return 0
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

# ── Update check ──────────────────────────────────────────────────────────────
# Pull the latest repo commits and return 0 if anything changed, 1 if not.
# Stores the deployed commit hash in COMMIT_FILE for comparison on next boot.

pull_and_check_update() {
    local repo_dir="${HIS_DIR}/repo"
    [ -d "${repo_dir}/.git" ] || return 1

    local before after
    before=$(git -C "${repo_dir}" rev-parse HEAD 2>/dev/null || echo "unknown")

    log "Checking for HIS repo updates…"
    git -C "${repo_dir}" pull --ff-only 2>&1 | tail -3 || true

    after=$(git -C "${repo_dir}" rev-parse HEAD 2>/dev/null || echo "unknown")
    local last_deployed
    last_deployed=$(cat "${COMMIT_FILE}" 2>/dev/null || echo "")

    if [ "${after}" != "${last_deployed}" ]; then
        log "Update detected: ${last_deployed:0:8} → ${after:0:8}"
        echo "${after}" > "${COMMIT_FILE}"
        return 0   # updated
    fi

    log "Already up to date (${after:0:8})."
    return 1   # no change
}

# ── Proxy mode ────────────────────────────────────────────────────────────────

run_proxy() {
    log "Proxy mode — forwarding HA ingress → his_gateway:8000"

    if [ -f "${COMPOSE_FILE}" ]; then
        if pull_and_check_update; then
            log "Rebuilding and recreating containers after update…"
            compose_up --build --force-recreate 2>&1 | tail -20 || true
        else
            log "Ensuring HIS stack is up…"
            compose_up 2>&1 | tail -10 || true
        fi
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
