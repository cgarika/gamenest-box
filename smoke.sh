#!/bin/bash
# GameNest 2.0 smoke test, through Caddy exactly as players arrive (prod_v2, 2026-11-15). Read-only; prints no secret.
#   smoke.sh box     on the box: needasix.com's routes on http://127.0.0.1 (Host: needasix.com, as Cloudflare sends it), and the
#                    gamenestapp.com routes v1 apps use on https://gamenestapp.com resolved to this box (its own certificate)
#   smoke.sh local   the local proof on this Mac (Caddy on 5657)
# Exit 0 only if every check passes.
set -uo pipefail
MODE=${1:-box}
if [ "$MODE" = local ]; then
  N=(http://127.0.0.1:5657); NH=(); G=(http://127.0.0.1:5657); GH=(-H "Host: gamenestapp.localhost:5657")
else
  N=(http://127.0.0.1); NH=(-H "Host: needasix.com"); G=(https://gamenestapp.com); GH=(--resolve gamenestapp.com:443:127.0.0.1)
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
row() { printf '  %-34s %s\n' "$1" "$2"; }
check_sock() { # label url-prefix extra-curl-args...
  local label=$1 url=$2; shift 2
  local code body
  code=$(curl -s -m 10 -o "$T/b" -w '%{http_code}' "$@" "$url/socket.io/?EIO=4&transport=polling" 2>/dev/null); body=$(head -c 2 "$T/b" 2>/dev/null)
  if [ "$code" = 200 ] && [ "$body" = '0{' ]; then row "$label" "ok (socket.io handshake)"; else row "$label" "FAILED (HTTP $code)"; fails=$((fails+1)); fi
}
check_code() { # label want url extra-curl-args...
  local label=$1 want=$2 url=$3; shift 3
  local code; code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null)
  if [ "$code" = "$want" ]; then row "$label" "ok ($code)"; else row "$label" "FAILED (HTTP $code, want $want)"; fails=$((fails+1)); fi
}
echo "needasix.com (v2 apps, the web pages):"
for slug in ludo snakes eights rummy mafia spies punchlines golf four chess bowling brawl carrom soccer pool poker blackjack; do
  check_sock "/$slug socket" "${N[0]}/$slug" "${NH[@]+"${NH[@]}"}"
  check_code "/$slug/ page" 200 "${N[0]}/$slug/" "${NH[@]+"${NH[@]}"}"
done
code=$(curl -s -m 10 -o "$T/w" -w '%{http_code}' "${NH[@]+"${NH[@]}"}" "${N[0]}/wallet/health"); grep -q '"ok":true' "$T/w" 2>/dev/null && [ "$code" = 200 ] \
  && row "/wallet/health" "ok ($(grep -o '"schema":[0-9]*' "$T/w"), $(grep -o '"apple":{"ready":[a-z]*' "$T/w" | sed 's/"apple":{"ready":/apple ready /'))" \
  || { row "/wallet/health" "FAILED (HTTP $code)"; fails=$((fails+1)); }
check_code "/wallet/v1/admin/summary hidden" 404 "${N[0]}/wallet/v1/admin/summary" "${NH[@]+"${NH[@]}"}"
check_code "/ludo/internal/roster hidden" 404 "${N[0]}/ludo/internal/roster/ABCDEF" "${NH[@]+"${NH[@]}"}"
check_code "/internal/roster hidden" 404 "${N[0]}/internal/roster/ABCDEF" "${NH[@]+"${NH[@]}"}"
check_code "/chess/stats/summary hidden" 404 "${N[0]}/chess/stats/summary" "${NH[@]+"${NH[@]}"}"
check_code "/ arcade page" 200 "${N[0]}/" "${NH[@]+"${NH[@]}"}"
if [ "$MODE" != local ]; then   # teenpatti is v1's own, unchanged: reported, never a failure of v2
  c=$(curl -s -m 10 -o "$T/tp" -w '%{http_code}' "${NH[@]}" "${N[0]}/teenpatti/socket.io/?EIO=4&transport=polling"); row "/teenpatti socket (v1, as before)" "HTTP $c $(head -c 2 "$T/tp")"
fi
echo "gamenestapp.com (the v1 app's sockets):"
for slug in ludo snakes eights rummy mafia spies punchlines; do check_sock "/$slug socket" "${G[0]}/$slug" "${GH[@]}"; done
check_code "/ website" 200 "${G[0]}/" "${GH[@]}"
if [ $fails = 0 ]; then echo "SMOKE OK: every check passed"; else echo "SMOKE FAILED: $fails check(s) failed"; exit 1; fi
