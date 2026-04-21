#!/bin/sh
# Resolves the Heimdallm API token and renders /etc/nginx/conf.d/default.conf
# from /etc/nginx/templates/heimdallm.conf.template.
#
# Precedence (matches the SvelteKit web_ui that this container replaces):
#   1. $HEIMDALLM_API_TOKEN env var (trimmed)
#   2. $HEIMDALLM_API_TOKEN_FILE (default /data/api_token), trimmed
#   3. empty → proxy will get no token; /api requests will 403/502.
#
# Also defaults ${DAEMON_URL} to http://heimdallm:7842 for the compose
# default network.
set -eu

: "${DAEMON_URL:=http://heimdallm:7842}"
TOKEN_FILE="${HEIMDALLM_API_TOKEN_FILE:-/data/api_token}"

if [ -n "${HEIMDALLM_API_TOKEN:-}" ]; then
  API_TOKEN="$HEIMDALLM_API_TOKEN"
elif [ -r "$TOKEN_FILE" ]; then
  API_TOKEN="$(tr -d '\n\r' < "$TOKEN_FILE")"
else
  echo "heimdallm-web: no token in HEIMDALLM_API_TOKEN or $TOKEN_FILE — /api will fail" >&2
  API_TOKEN=""
fi

export API_TOKEN DAEMON_URL
envsubst '${API_TOKEN} ${DAEMON_URL}' \
  < /etc/nginx/heimdallm.conf.template \
  > /etc/nginx/conf.d/default.conf

if [ -n "$API_TOKEN" ]; then
  echo "heimdallm-web: upstream=${DAEMON_URL} token=present"
else
  echo "heimdallm-web: upstream=${DAEMON_URL} token=missing"
fi
