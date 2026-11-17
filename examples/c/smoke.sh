#!/usr/bin/env bash
# Offline smoke test of the C example: lw_cli <state> check | activate | deactivate
# with no server (nothing listens on port 9). The full end-to-end check, against a
# real local License Worker, is License Worker's `npm run check:clients` with
# LW_C_CLIENT pointing at lw_cli.
set -euo pipefail
cli="$1"
state="$(mktemp -d)/licence.json"
export LW_URL="http://127.0.0.1:9"
export LW_PUBLIC_KEYS='{"k1":"MwhKI3s/ZgWNKaAhSHr9JM8YjI5bEuFREV5QcIWDJiY=","k2":"MHTLL2mbYkq6vfQO/O9AEAMtLeEseiyWCb5sOq+ZDGc="}'
export LW_PRODUCT_IDS="4100105"

expect() {
  local got="$1" want="$2"
  got="${got%$'\r'}"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: got  $got"
    echo "      want $want"
    exit 1
  fi
  echo "ok   $want"
}

expect "$("$cli" "$state" check)" '{"unlocked":false,"state":"inactive","reason":null}'
expect "$("$cli" "$state" activate 38b1460a-5104-4067-a91d-77b872934d51)" \
  '{"ok":false,"error":"The licence server could not be reached. Check the connection and try again."}'
[[ ! -e "$state" ]] || { echo "FAIL: activation offline stored something"; exit 1; }
expect "$("$cli" "$state" deactivate)" '{"ok":true}'
expect "$(LW_URL="" "$cli" "$state" check)" '{"ok":false,"error":"server_url is required"}'
echo "C example: all smoke checks pass"
