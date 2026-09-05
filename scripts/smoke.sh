#!/usr/bin/env sh
set -eu
curl -fsS "https://${ASSIS_DOMAIN}/healthz" >/dev/null || curl -fsS "https://${ASSIS_DOMAIN}/" >/dev/null
printf 'PASS: endpoint reachable
'
