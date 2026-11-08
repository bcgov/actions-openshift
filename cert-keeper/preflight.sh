#!/usr/bin/env bash
# HTTP-01 needs plain HTTP on port 80 to reach the OpenShift router. Fail early
# with a clear reason instead of waiting out the timeout. Any HTTP answer counts,
# including a redirect or a 503; only no answer fails.
set -euo pipefail

HOST="${HOST:-}"
TIMEOUT="${PREFLIGHT_TIMEOUT:-10}"

[ -n "$HOST" ] || { echo "::error title=cert-keeper::HOST is required."; exit 1; }

code="$(curl -sS -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "http://${HOST}/.well-known/acme-challenge/cert-keeper-preflight" 2> /dev/null || true)"
case "$code" in
  "" | 000)
    echo "::error title=cert-keeper::Port 80 on ${HOST} did not answer within ${TIMEOUT}s."
    echo "Fix: point ${HOST} at the OpenShift router and allow plain HTTP on port 80; the CA validates ownership over HTTP-01."
    exit 1 ;;
esac
echo "Port 80 answers for ${HOST} (HTTP ${code})."
