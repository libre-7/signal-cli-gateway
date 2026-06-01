#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh - signal-cli-gateway security mode orchestrator
# =============================================================================
# This script runs as PID 1 inside the container. It manages the signal-cli
# daemon and optionally the secured-signal-api proxy, handling signal
# forwarding, health checks, and child-process supervision.
# =============================================================================
set -euo pipefail

# --- Helpers ----------------------------------------------------------------
log()  { echo "[entrypoint] $(date -Iseconds) $*"; }
die()  { log "FATAL: $*"; exit 1; }
warn() { log "WARN: $*"; }

# Cleanup handler — forward SIGTERM/SIGINT to children
CHILDREN_PIDS=""
cleanup() {
    local sig=$1
    log "Received ${sig}, forwarding to children (PIDs: ${CHILDREN_PIDS})..."
    for pid in ${CHILDREN_PIDS}; do
        kill -"${sig}" "${pid}" 2>/dev/null || true
    done
    wait
    log "All children exited. Goodbye."
    exit 0
}
trap 'cleanup TERM' TERM INT

# --- Validate environment ---------------------------------------------------
SIGNAL_ACCOUNT="${SIGNAL_ACCOUNT:-}"
SECURITY_MODE="${SECURITY_MODE:-loopback}"

# SIGNAL_ACCOUNT is always required
if [ -z "${SIGNAL_ACCOUNT}" ]; then
    die "SIGNAL_ACCOUNT is required (your phone number in E.164 format, e.g. +123****7890)"
fi

# Validate security mode
case "${SECURITY_MODE}" in
    loopback|loopback-proxy|exposed-proxy|unix)
        log "Security mode: ${SECURITY_MODE}"
        ;;
    *)
        die "Invalid SECURITY_MODE='${SECURITY_MODE}'. Must be: loopback, loopback-proxy, exposed-proxy, unix"
        ;;
esac

# --- Build signal-cli args --------------------------------------------------
SIGNAL_CLI_PORT="${SIGNAL_CLI_PORT:-8080}"
SIGNAL_TRUST="${SIGNAL_CLI_TRUST_NEW_IDENTITIES:-on-first-use}"

SIGNAL_CLI_ARGS=(
    "--config" "/opt/signal-cli-data"
    "--trust-new-identities" "${SIGNAL_TRUST}"
)

# Append optional ignore flags — native binary doesn't support daemon-level ignore flags
# These are only for JVM build. Native skips them.
true

# --- Signal CLI daemon helper (used by multiple modes) ----------------------
start_signal_cli() {
    local bind="${1:-127.0.0.1}"
    log "Starting signal-cli daemon on ${bind}:${SIGNAL_CLI_PORT}..."

    # Ensure data directory is writable by the signal user
    chown -R signal:signal /opt/signal-cli-data 2>/dev/null || true

    gosu signal signal-cli "${SIGNAL_CLI_ARGS[@]}" \
        daemon --http "${bind}:${SIGNAL_CLI_PORT}" &
    local pid=$!
    CHILDREN_PIDS="${CHILDREN_PIDS} ${pid}"

    # Wait for daemon to be ready
    log "Waiting for signal-cli daemon to be ready..."
    for i in $(seq 1 30); do
        if curl -sf "http://${bind}:${SIGNAL_CLI_PORT}/api/v1/check" >/dev/null 2>&1; then
            log "signal-cli daemon is ready."
            return 0
        fi
        sleep 1
    done
    die "signal-cli daemon failed to start within 30 seconds"
}

# --- Proxy config generator -------------------------------------------------
write_proxy_config() {
    local proxy_port="${1:-8880}"
    local proxy_token="${2:-}"
    local proxy_allowed_ips="${3:-127.0.0.1,172.0.0.0/8,10.0.0.0/8}"

    # Generate a random proxy token if none provided
    if [ -z "${proxy_token}" ]; then
        proxy_token="$(openssl rand -hex 32)"
        log "SECURITY_PROXY_TOKEN not set — generated random token (visible once):"
        log "  >>>  ${proxy_token}  <<<"
        log "  Set SECURITY_PROXY_TOKEN in .env to use a fixed token."
    fi

    # Build trusted IPs YAML list
    local trusted_ips_yaml=""
    IFS=',' read -ra ips <<< "${proxy_allowed_ips}"
    for ip in "${ips[@]}"; do
        ip="$(echo "${ip}" | xargs)"
        [ -n "${ip}" ] && trusted_ips_yaml="${trusted_ips_yaml}      - \"${ip}\"\n"
    done

    # Write config file
    cat > /config/config.yml << PROXYCFG
service:
  logLevel: ${LOG_LEVEL:-info}
  port: ${proxy_port}

api:
  url: http://127.0.0.1:${SIGNAL_CLI_PORT}
  tokens:
    - "${proxy_token}"
  auth:
    methods: [bearer, basic]

settings:
  access:
    trustedIPs:
$(printf "${trusted_ips_yaml}")
    cors:
      methods: [GET, POST]
      headers: ["Content-Type"]
      origins:
        - url: "http://localhost"
PROXYCFG

    log "Proxy config written to /config/config.yml"
    log "Proxy token set: ${proxy_token:0:8}... (truncated)"

    # Export token and config path for proxy to pick up
    export SECURITY_PROXY_TOKEN="${proxy_token}"
    export CONFIG_PATH=/config/config.yml
}

# --- Mode-specific startup --------------------------------------------------
case "${SECURITY_MODE}" in
    loopback)
        start_signal_cli "127.0.0.1"
        ;;

    loopback-proxy)
        start_signal_cli "127.0.0.1"
        write_proxy_config "${PROXY_PORT:-8880}" "${SECURITY_PROXY_TOKEN:-}" "${SECURITY_PROXY_ALLOWED_IPS:-127.0.0.1,172.0.0.0/8,10.0.0.0/8}"

        log "Starting secured-signal-api proxy on 127.0.0.1:${PROXY_PORT:-8880}..."
        /opt/secured-signal-api/secured-signal-api &
        CHILDREN_PIDS="${CHILDREN_PIDS} $!"
        ;;

    exposed-proxy)
        start_signal_cli "127.0.0.1"
        write_proxy_config "${PROXY_PORT:-8880}" "${SECURITY_PROXY_TOKEN:-}" "${SECURITY_PROXY_ALLOWED_IPS:-127.0.0.1,172.0.0.0/8,10.0.0.0/8}"

        log "Starting secured-signal-api proxy on 0.0.0.0:${PROXY_PORT:-8880}..."
        /opt/secured-signal-api/secured-signal-api &
        CHILDREN_PIDS="${CHILDREN_PIDS} $!"
        ;;

    unix)
        local socket_path="/var/run/signal-cli/socket"
        mkdir -p "$(dirname "${socket_path}")"

        log "Starting signal-cli daemon on UNIX socket ${socket_path}..."
        gosu signal signal-cli "${SIGNAL_CLI_ARGS[@]}" \
            daemon --socket "${socket_path}" &
        CHILDREN_PIDS="${CHILDREN_PIDS} $!"

        # Wait for socket to appear
        for i in $(seq 1 30); do
            if [ -S "${socket_path}" ]; then
                log "UNIX socket ready."
                break
            fi
            sleep 1
        done

        # socat bridge: TCP → UNIX socket
        log "Starting socat bridge on 127.0.0.1:${SIGNAL_CLI_PORT} → ${socket_path}..."
        socat "TCP-LISTEN:${SIGNAL_CLI_PORT},bind=127.0.0.1,fork,reuseaddr" \
              "UNIX-CONNECT:${socket_path}" &
        CHILDREN_PIDS="${CHILDREN_PIDS} $!"
        ;;
esac

# --- Wait for all children --------------------------------------------------
log "All processes started. Monitoring children (PIDs: ${CHILDREN_PIDS})..."
wait
