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
echo "Device name: ${DEVICE_NAME}"
echo ""

# Run the link command and capture just the URI line
LINK_URI=$(signal-cli --config /opt/signal-cli-data link -n "${DEVICE_NAME}" 2>&1 | grep -o 'sgnl://[^ ]*' | head -1)

echo ""
echo "================================================"
echo " Device Link URI:"
echo "  ${LINK_URI}"
echo ""
echo " QR Code URL (open in browser and scan):"
QR_DATA=$(echo "${LINK_URI}" | sed 's/&/%26/g')
echo "  https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${QR_DATA}"
echo "================================================"
echo ""
echo "Open the QR URL, then scan from:"
echo "  Signal app → Settings → Linked Devices → +"
