ARG BUILD_FROM
ARG BUILD_ARCH=amd64
FROM ${BUILD_FROM:-ghcr.io/home-assistant/${BUILD_ARCH}-base:latest}

# ── System packages ───────────────────────────────────────────────────────────
RUN apk add --no-cache \
    python3 py3-pip \
    docker-cli docker-cli-compose \
    nginx \
    git \
    curl \
    bash \
    jq \
    openssl

# ── Python deps for orchestrator wizard ───────────────────────────────────────
RUN pip3 install --no-cache-dir --break-system-packages \
    fastapi uvicorn[standard]

# ── Orchestrator app ───────────────────────────────────────────────────────────
COPY orchestrator/ /orchestrator/

# ── nginx config ──────────────────────────────────────────────────────────────
COPY nginx.conf /etc/nginx/nginx.conf

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
