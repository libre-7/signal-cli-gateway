#!/bin/bash
# =============================================================================
# signal-cli-gateway Unraid One-Time Build & Link Helper
# =============================================================================
# Run this ONCE from Unraid terminal (Tools → Terminal or SSH).
# Builds the image, then you can use the Unraid Docker UI template.
#
# Usage: bash build-signal-gateway.sh
# =============================================================================
set -euo pipefail

GIT_REPO="https://github.com/libre-7/signal-cli-gateway.git"
BUILD_DIR="/tmp/signal-cli-gateway"
DATA_DIR="/mnt/user/appdata/signal-cli-gateway"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  signal-cli-gateway Build for Unraid                    ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Clone
echo "━━━ Step 1: Clone repo ━━━"
if [ -d "$BUILD_DIR" ]; then
  echo "Repo already exists at $BUILD_DIR, pulling latest..."
  cd "$BUILD_DIR" && git pull
else
  git clone "$GIT_REPO" "$BUILD_DIR"
  cd "$BUILD_DIR"
fi

# Step 2: Build
echo ""
echo "━━━ Step 2: Build Docker image (2-5 minutes) ━━━"
docker build -t signal-cli-gateway:latest .

# Step 3: Create data dir
echo ""
echo "━━━ Step 3: Create persistent data directory ━━━"
mkdir -p "$DATA_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  BUILD COMPLETE"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo ""
echo "  1. Link your phone (one-time):"
echo "     docker run --rm -it \\"
echo "       -v $DATA_DIR:/opt/signal-cli-data \\"
echo "       -e SIGNAL_ACCOUNT=+130****7101 \\"
echo "       -e DEVICE_NAME=HermesAgent \\"
echo "       signal-cli-gateway:latest \\"
echo "       bash /scripts/link-account.sh"
echo ""
echo "  2. Convert the URI to QR and scan with Signal app:"
echo "     Settings → Linked Devices → Link New Device"
echo ""
echo "  3. Install template in Unraid Docker UI:"
echo "     - Docker → Add Container"
echo "     - Repository: signal-cli-gateway:latest"
echo "     - Network: Host"
echo "     - Set SIGNAL_ACCOUNT env var"
echo "     - Set data volume to $DATA_DIR"
echo "     - Apply"
echo ""
echo "  4. Configure Hermes .env:"
echo "     SIGNAL_HTTP_URL=http://127.0.0.1:8880"
echo "     SIGNAL_ACCOUNT=+130****7101"
echo "     SIGNAL_HOME_CHANNEL=+130****7101"
echo ""
echo "  5. Restart Hermes gateway:"
echo "     docker exec -it hermes-webui /app/venv/bin/hermes gateway restart"
echo ""
