#!/bin/bash
# =============================================================================
# test-proxy.sh - verify secured-signal-api proxy authentication
#
# Usage: ./test-proxy.sh <token> [proxy_host] [proxy_port]
#
# Expects:
#   - HTTP 200 with a valid Bearer token
#   - HTTP 401/403 without auth (or with an invalid token)
#
# Exits non-zero on any failure. Proxy host/port default to the compose
# defaults; override when using custom PROXY_PORT.
# =============================================================================
set -euo pipefail

TOKEN="${1:-}"
PROXY_HOST="${2:-127.0.0.1}"
PROXY_PORT="${3:-${PROXY_PORT:-8880}}"

if [ -z "${TOKEN}" ]; then
    echo "Usage: $0 <token> [proxy_host] [proxy_port]" >&2
    exit 2
fi

URL="http://${PROXY_HOST}:${PROXY_PORT}/api/v1/check"
FAIL=0

echo "=== Authenticated request (Bearer token) — expect 200 ==="
AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${URL}" || true)
echo "HTTP ${AUTH_CODE}"
if [ "${AUTH_CODE}" != "200" ]; then
    echo "FAIL: authenticated request did not return 200" >&2
    FAIL=1
fi

echo ""
echo "=== Unauthenticated request — expect 401 or 403 ==="
NOAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${URL}" || true)
echo "HTTP ${NOAUTH_CODE}"
case "${NOAUTH_CODE}" in
    401|403) ;;
    *) echo "FAIL: unauthenticated request returned ${NOAUTH_CODE}, expected 401/403" >&2; FAIL=1 ;;
esac

echo ""
echo "=== Invalid token — expect 401 or 403 ==="
BAD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer invalid-token-should-fail" "${URL}" || true)
echo "HTTP ${BAD_CODE}"
case "${BAD_CODE}" in
    401|403) ;;
    *) echo "FAIL: invalid token returned ${BAD_CODE}, expected 401/403" >&2; FAIL=1 ;;
esac

if [ "${FAIL}" -ne 0 ]; then
    echo "" >&2
    echo "RESULT: FAIL" >&2
    exit 1
fi

echo ""
echo "RESULT: PASS (auth enforced correctly)"
