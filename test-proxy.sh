#!/bin/bash
# Test script for signal-cli-gateway
# Usage: ./test-proxy.sh [token]
set -euo pipefail

TOKEN="${1:-}"
[ -n "${1:-}" ] && TOKEN="$1"

echo "=== Authenticated request ==="
curl -v -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8880/api/v1/check 2>&1 | head -15

echo ""
echo "=== No auth (expect 401/403) ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8880/api/v1/check

echo ""
echo "=== Health check ==="
curl -sf http://127.0.0.1:8080/api/v1/check && echo " daemon OK" || echo " daemon FAIL"
