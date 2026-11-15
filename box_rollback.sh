#!/bin/bash
# GameNest 2.0: back to v1 on THIS instance, in one paste:  bash ~/gamenest-v2/kit/box_rollback.sh
# (The quickest way back is the other one: move the static IP back to the old instance, which still runs v1 untouched; OWNER_STEPS.md.)
# What it does, from the v1 original box_deploy.sh saved (~/backups/gamenest-v1-original):
#   1. puts the v1 Caddyfile back (checked by Caddy first) and reloads Caddy
#   2. takes the v2 overlay line out of ~/arcade/.env
#   3. docker compose with the box's own file only: the seven v1 games go back to their v1 images (still on the box), and the nine new
#      games and the wallet stop and are removed (their containers only)
#   4. checks the seven v1 games and teenpatti answer, on needasix.com's routes and on gamenestapp.com's
# It never deletes data: v2's folders (~/data/<slug>, ~/secrets/gamenest-v2, ~/gamenest-v2) stay, so going forward again is box_deploy.sh.
# Needs no internet. Prints no secret. Stops at the first problem.
set -Eeuo pipefail
ARCADE=/home/ubuntu/arcade
ORIG=/home/ubuntu/backups/gamenest-v1-original
STEP="starting"
stop() { echo; echo "ROLLBACK STOPPED at: $STEP"; echo "   $*"; exit 1; }
trap 'rc=$?; [ $rc -eq 0 ] || echo "ROLLBACK STOPPED at: $STEP (exit $rc)"' EXIT
step() { STEP="$1"; echo; echo "== $(date -u '+%H:%M:%S') $1"; }
DC1() { docker compose --project-directory "$ARCADE" -f "$ARCADE/docker-compose.yml" "$@"; }

step "1/4 the v1 original"
[ -f "$ORIG/DONE" ] && [ -f "$ORIG/docker-compose.yml" ] && [ -f "$ORIG/MANIFEST.txt" ] || stop "No v1 original in $ORIG (box_deploy.sh saves it on its first run). Use the static IP instead (OWNER_STEPS.md)."
CADDYFILE=$(sed -n 's/^Caddyfile came from: //p' "$ORIG/MANIFEST.txt")
[ -n "$CADDYFILE" ] && [ -f "$ORIG/$(basename "$CADDYFILE")" ] || stop "The saved Caddyfile is missing from $ORIG."
cmp -s "$ORIG/docker-compose.yml" "$ARCADE/docker-compose.yml" || stop "$ARCADE/docker-compose.yml differs from the v1 original: someone changed it after the deploy. Ask the lead."
echo "   v1 original from $(head -1 "$ORIG/MANIFEST.txt" | sed 's/^v1 as it was on //')"

step "2/4 the v1 Caddyfile"
cid=$(DC1 ps -q caddy); [ -n "$cid" ] || stop "the caddy container is not running"
docker cp "$ORIG/$(basename "$CADDYFILE")" "$cid:/tmp/Caddyfile.v1" >/dev/null
docker exec "$cid" caddy validate --config /tmp/Caddyfile.v1 --adapter caddyfile >/dev/null 2>&1 || stop "Caddy does not accept the saved v1 Caddyfile; nothing was changed."
sudo cp -p "$CADDYFILE" "/home/ubuntu/backups/Caddyfile.before-rollback-$(date -u '+%Y%m%d-%H%M%S')"
sudo tee "$CADDYFILE" < "$ORIG/$(basename "$CADDYFILE")" > /dev/null   # in place: the same file Caddy's container has mounted
if docker exec "$cid" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then echo "   Caddy reloaded with v1's routes"
else DC1 restart caddy >/dev/null && echo "   Caddy restarted with v1's routes"; fi
if [ -f "$ARCADE/.env" ]; then
  sudo sed -i -e '/^# GameNest 2.0 (box_deploy.sh): docker compose in this folder also reads the v2 overlay$/d' \
              -e '\#^COMPOSE_FILE=docker-compose.yml:/home/ubuntu/gamenest-v2/kit/compose/docker-compose.v2.yml$#d' "$ARCADE/.env"
  echo "   ~/arcade/.env no longer names the v2 overlay"
fi

step "3/4 v1's containers"
DC1 up -d --remove-orphans 2>&1 | sed 's/^/   /'
echo "   the nine new games and the wallet are stopped and removed; their data stays in /home/ubuntu/data"

step "4/4 checks"
fails=0
for slug in ludo snakes eights rummy mafia spies punchlines teenpatti; do
  for i in $(seq 1 30); do c=$(curl -s -m 5 -o /tmp/rb.$$ -w '%{http_code}' -H 'Host: needasix.com' "http://127.0.0.1/$slug/socket.io/?EIO=4&transport=polling" || true); [ "$c" = 200 ] && break; sleep 1; done
  if [ "$c" = 200 ] && [ "$(head -c 2 /tmp/rb.$$)" = '0{' ]; then r=ok; else r="FAILED ($c)"; [ $slug = teenpatti ] && r="HTTP $c (teenpatti is v1's own; reported only)" || fails=$((fails+1)); fi
  printf '   needasix.com/%-11s %s\n' "$slug" "$r"
done
for slug in ludo snakes eights rummy mafia spies punchlines; do
  c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' --resolve gamenestapp.com:443:127.0.0.1 "https://gamenestapp.com/$slug/socket.io/?EIO=4&transport=polling" || true)
  printf '   gamenestapp.com/%-8s %s\n' "$slug" "$([ "$c" = 200 ] && echo ok || echo "FAILED ($c)")"; [ "$c" = 200 ] || fails=$((fails+1))
done
rm -f /tmp/rb.$$
[ $fails = 0 ] || stop "$fails check(s) failed (above)."
echo; echo "ROLLBACK OK $(date -u '+%Y-%m-%d %H:%M UTC'): this instance runs v1 again. v2's data and sources are kept; box_deploy.sh goes forward again."
