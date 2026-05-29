#!/bin/bash
# =============================================================================
# link-account.sh — Link a Signal account as a secondary device
# =============================================================================
# Run this ONCE to link your phone to the signal-cli daemon.
# Usage: docker run --rm -it -v signal-cli-data:/opt/signal-cli-data \
#        signal-cli-gateway bash /scripts/link-account.sh
# =============================================================================
set -euo pipefail

DEVICE_NAME="${DEVICE_NAME:-SignalGateway}"

echo "================================================"
echo " Signal Account Linking"
echo "================================================"
echo ""
echo "This will generate a QR code URI for linking signal-cli"
echo "as a secondary device to your Signal account."
echo ""
echo "Device name: ${DEVICE_NAME}"
echo ""

# Run the link command
signal-cli --config /opt/signal-cli-data link -n "${DEVICE_NAME}"
