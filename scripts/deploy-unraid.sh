#!/bin/bash
# =============================================================================
# deploy-signal-gateway.sh — One-shot deploy for Unraid
# =============================================================================
# Run this from your Unraid host terminal (SSH or local).
# Builds the image, links your phone, and starts the daemon.
# =============================================================================
set -euo pipefail

# === CONFIGURATION — EDIT THESE ===
SIGNAL_NUMBER="+13065267101"
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
echo "A device link URI will appear below. Convert it to a QR code:"
echo ""
echo "  Option A — Install qrencode (Unraid NerdPack):"
echo "    qrencode -t ANSI256 'sgnl://linkdevice?...'"
echo ""
echo "  Option B — Use the web by pasting the URI at:"
echo "    https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=URI_HERE"
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
read -p "Press Enter to continue..."

# --- Step 5: Remove old container if exists ---
echo ""
echo "━━━ Step 5: Start daemon ━━━"
docker rm -f signal-cli-gateway 2>/dev/null || true

# --- Step 6: Run daemon ---
docker run -d --name signal-cli-gateway --restart unless-stopped \
  --network host \
  -v "${DATA_DIR}:/opt/signal-cli-data" \
  -e SIGNAL_ACCOUNT="${SIGNAL_NUMBER}" \
  -e SECURITY_MODE=loopback-proxy \
  signal-cli-gateway:latest

echo ""
echo "━━━ Step 6: Verify ━━━"
sleep 3

echo ""
echo "--- Daemon health ---"
curl -sf http://127.0.0.1:8080/api/v1/check && echo " ✅ daemon OK" || echo " ❌ daemon FAIL"

echo ""
echo "--- Proxy health ---"
curl -sf http://127.0.0.1:8880/api/v1/check && echo " ✅ proxy OK" || echo " ❌ proxy FAIL"

echo ""
echo "--- Proxy token (needed for Hermes .env) ---"
docker logs signal-cli-gateway 2>&1 | grep ">>>" || echo "(check 'docker logs signal-cli-gateway' for the token)"

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
