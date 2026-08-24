#!/bin/bash
# =============================================================================
# link-account.sh — Link a Signal account as a secondary device
# =============================================================================
# Run this ONCE to link your phone to the signal-cli daemon.
# Usage: docker run --rm -it -v signal-cli-data:/opt/signal-cli-data \
#        signal-cli-gateway bash /scripts/link-account.sh
#
# Fully offline: the QR code is rendered locally with qrencode (ANSI256).
# No third-party service (api.qrserver.com or similar) is ever contacted.
# =============================================================================
set -euo pipefail

DEVICE_NAME="${DEVICE_NAME:-SignalGateway}"

echo "================================================"
echo " Signal Account Linking"
echo "================================================"
echo ""
echo "Device name: ${DEVICE_NAME}"
echo ""

if ! command -v signal-cli >/dev/null 2>&1; then
    echo "FATAL: signal-cli not found in PATH." >&2
    exit 1
fi
if ! command -v qrencode >/dev/null 2>&1; then
    echo "FATAL: qrencode not installed (required for offline QR rendering)." >&2
    exit 1
fi

# Run the link command, capturing stderr (where the URI is printed) while
# letting any non-URI output flow through. The URI is extracted from the raw
# stream afterwards so grep cannot SIGPIPE-kill signal-cli mid-link.
TMP_OUT="$(mktemp)"
trap 'rm -f "${TMP_OUT}"' EXIT

signal-cli --config /opt/signal-cli-data link -n "${DEVICE_NAME}" 2>&1 | tee "${TMP_OUT}" >/dev/null || true

LINK_URI="$(grep -o 'sgnl://[^ ]*' "${TMP_OUT}" | head -1)"

if [ -z "${LINK_URI}" ]; then
    echo "================================================" >&2
    echo "FATAL: no sgnl:// link URI was produced by" >&2
    echo "'signal-cli link'. Check the output above for errors" >&2
    echo "(e.g. network issues reaching Signal servers)." >&2
    echo "================================================" >&2
    exit 1
fi

echo ""
echo "================================================"
echo " Device Link URI:"
echo "  ${LINK_URI}"
echo ""
echo " Scan this QR code from: Signal app → Settings → Linked Devices → +"
echo "================================================"
qrencode -t ANSI256 -- "${LINK_URI}"
echo "QR code rendered locally — nothing left this machine."
