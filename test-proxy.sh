#!/bin/bash
# Test script for signal-cli-gateway
set -e

echo "=== Authenticated request ==="
curl -v -H "Authorization: Bearer *** http://127.0.0.1:8880/api/v1/check 2>&1 | head -15

echo ""
echo "=== No auth (expect 401/403) ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8880/api/v1/check

echo ""
echo "=== Generated config ==="
docker exec scg-test cat /config/config.yml 2>&1 || echo "(container gone)"