#!/usr/bin/env bash
# Refuses to let the install step rewrite a Route that is not this host's. The
# install step applies the whole Route (host, backend, edge termination with a redirect), so
# an existing Route with this name that serves another host, or terminates TLS
# some other way, would be changed without a word. This runs before a
# certificate is issued, so a refusal wastes none of the rate limit.
set -euo pipefail

ROUTE_NAME="${ROUTE_NAME:-}"
HOST="${HOST:-}"
TARGET_SERVICE="${TARGET_SERVICE:-}"
OC="${OC:-oc}"

die() {
  echo "::error title=cert-keeper::$1"
  echo "Fix: $2"
  exit 1
}

[ -n "$ROUTE_NAME" ] && [ -n "$HOST" ] || die "ROUTE_NAME and HOST are required." "Pass route_name and hostname."

row="$("$OC" get route "$ROUTE_NAME" --ignore-not-found -o 'jsonpath={.spec.host}|{.spec.tls.termination}|{.spec.to.name}')" \
  || die "Could not read Route ${ROUTE_NAME}." "Check the token can get routes in the namespace and the API answers."

if [ -z "$row" ]; then
  echo "Route ${ROUTE_NAME} does not exist yet; the install step will create it."
  exit 0
fi

IFS='|' read -r r_host r_term r_svc <<< "$row"

[ "${r_host,,}" = "${HOST,,}" ] \
  || die "Route ${ROUTE_NAME} serves '${r_host}', not '${HOST}'." "Set route_name to the Route for ${HOST}, or to a new name. cert-keeper only rewrites a Route for the host it is given."

case "$r_term" in
  "" | edge) ;;
  *) die "Route ${ROUTE_NAME} uses ${r_term} termination; cert-keeper would change it to edge." "Terminate TLS on the Route (edge), or manage this Route's certificate another way." ;;
esac

if [ -n "$r_svc" ] && [ "$r_svc" != "$TARGET_SERVICE" ]; then
  echo "::warning title=cert-keeper::Route ${ROUTE_NAME} sends traffic to '${r_svc}'; it will be changed to '${TARGET_SERVICE}'."
fi
echo "Route ${ROUTE_NAME} is the Route for ${r_host} (${r_term:-no TLS yet})."
