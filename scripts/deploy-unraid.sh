#!/bin/bash
# =============================================================================
# deploy-signal-gateway.sh — One-shot deploy for Unraid
# =============================================================================
# Run this from your Unraid host terminal (SSH or local).
# Builds the image, links your phone, and starts the daemon.
# =============================================================================
set -euo pipefail

# === CONFIGURATION — EDIT THESE ===
SIGNAL_NUMBER="${SIGNAL_NUMBER:-+123****7890}"
DEVICE_NAME="HermesAgent"
DATA_DIR="/mnt/user/appdata/signal-cli-gateway"
GIT_REPO="https://github.com/libre-7/signal-cli-gateway.git"
BUILD_DIR="/tmp/signal-cli-gateway"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  signal-cli-gateway Deploy for Unraid                    ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "Phone:     ${SIGNAL_NUMBER}"
echo "Data dir:  ${DATA_DIR}"
echo ""

# --- Step 1: Clone repo ---
echo "━━━ Step 1: Clone repo ━━━"
rm -rf "${BUILD_DIR}"
git clone "${GIT_REPO}" "${BUILD_DIR}"
cd "${BUILD_DIR}"

# --- Step 2: Build Docker image ---
echo ""
echo "━━━ Step 2: Build Docker image (this takes 2-5 minutes) ━━━"
docker build -t signal-cli-gateway:latest .

# --- Step 3: Create data directory ---
echo ""
echo "━━━ Step 3: Create data directory ━━━"
mkdir -p "${DATA_DIR}"

# --- Step 4: Link phone ---
echo ""
echo "━━━ Step 4: Link your phone ━━━"
echo ""
echo "A device link URI will appear below. Render a QR code locally:"
echo ""
echo "  Install qrencode (Unraid NerdPack), then run:"
echo "    qrencode -t ANSI256 'sgnl://linkdevice?...'"
echo ""
echo "  (Avoid third-party QR web services — the link URI grants full access"
echo "   to the account. Everything stays on this machine.)"
echo ""
echo "  Then scan from: Signal app → Settings → Linked Devices → +"
echo ""

docker run --rm -it \
  -v "${DATA_DIR}:/opt/signal-cli-data" \
  -e SIGNAL_ACCOUNT="${SIGNAL_NUMBER}" \
  -e DEVICE_NAME="${DEVICE_NAME}" \
  signal-cli-gateway:latest \
  bash /scripts/link-account.sh

echo ""
echo "━━━ After linking, proceed to Step 5 ━━━"
read -r -p "Press Enter to continue..." </dev/tty

# --- Step 5: Remove old container if exists ---
echo ""
echo "━━━ Step 5: Start daemon ━━━"
docker rm -f signal-cli-gateway 2>/dev/null || true

# --- Step 6: Run daemon ---
# Safe default: loopback (signal-cli on 127.0.0.1, no proxy).
# Set SECURITY_MODE=loopback-proxy to opt into the auth proxy on
# 0.0.0.0:8880 (exposes the HTTP API — bearer token + IP allowlist apply).
DEPLOY_MODE="${SECURITY_MODE:-loopback}"
docker run -d --name signal-cli-gateway --restart unless-stopped \
  --network host \
  -v "${DATA_DIR}:/opt/signal-cli-data" \
  -e SIGNAL_ACCOUNT="${SIGNAL_NUMBER}" \
  -e SECURITY_MODE="${DEPLOY_MODE}" \
  signal-cli-gateway:latest

echo ""
echo "━━━ Step 6: Verify ━━━"
echo "Mode: ${DEPLOY_MODE}"

# Give the daemon a moment to bind before probing.
for _ in $(seq 1 20); do
  curl -sf "http://127.0.0.1:8080/api/v1/check" >/dev/null 2>&1 && break
  sleep 1
done

echo ""
echo "--- Daemon health ---"
if curl -sf "http://127.0.0.1:8080/api/v1/check" >/dev/null 2>&1; then
  echo " ✅ daemon OK"
else
  echo " ❌ daemon FAIL — check 'docker logs signal-cli-gateway'"
fi

# Only probe the proxy in the modes that actually run one. Probing 127.0.0.1:8880
# in loopback/unix mode reports a bogus FAIL, because no proxy is listening
# there by design.
case "${DEPLOY_MODE}" in
  loopback-proxy|exposed-proxy)
    echo ""
    echo "--- Proxy health ---"
    if curl -sf "http://127.0.0.1:8880/api/v1/check" >/dev/null 2>&1; then
      echo " ✅ proxy OK"
    else
      echo " ❌ proxy FAIL — check 'docker logs signal-cli-gateway'"
    fi

    echo ""
    echo "--- Proxy token (needed for Hermes .env) ---"
    docker logs signal-cli-gateway 2>&1 | grep ">>>" \
      || echo "(no token in logs — set SECURITY_PROXY_TOKEN to pin one)"
    ;;
  *)
    echo ""
    echo "--- Proxy ---"
    echo " ⏭  skipped (mode '${DEPLOY_MODE}' runs no proxy; set SECURITY_MODE=loopback-proxy to enable)"
    ;;
esac

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  DEPLOYMENT COMPLETE"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Add to Hermes .env:"
echo "    SIGNAL_HTTP_URL=http://127.0.0.1:8880"
echo "    SIGNAL_ACCOUNT=${SIGNAL_NUMBER}"
echo "    SIGNAL_HOME_CHANNEL=${SIGNAL_NUMBER}"
echo ""
echo "  Then restart Hermes gateway:"
echo "    docker exec -it hermes-webui /app/venv/bin/hermes gateway restart"
echo ""
