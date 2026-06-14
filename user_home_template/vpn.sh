#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ./client.env ]; then
  echo "Error: missing $SCRIPT_DIR/client.env" >&2
  echo "Create it with USERNAME=... and PASSWORD=..." >&2
  exit 1
fi

set -a
source ./client.env
set +a

: "${USERNAME:?client.env must set USERNAME}"
: "${PASSWORD:?client.env must set PASSWORD}"
: "${REQUIRE_COUNTRY:?client.env must set REQUIRE_COUNTRY}"
: "${VPN_SERVER:?client.env must set VPN_SERVER}"
: "${VPN_PROTOCOL:?client.env must set VPN_PROTOCOL}"

python3 ./geo_check.py

if [ -z "${VPN_GATEWAY:-}" ] && [ -x ./set_gateway.sh ]; then
  . ./set_gateway.sh
fi

exec ./vpn.exp
