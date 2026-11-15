#!/bin/bash
# GameNest 2.0 on needasix.com: the ONE script the owner runs on the NEW Lightsail instance (made from a snapshot of the old box "ludo").
# It is safe to run again: every step checks what is already there. It stops at the first problem, prints plain progress, and never
# prints a secret (it never shows .env, the secrets folders, or `docker compose config`).
#
#   1. checks it is on the new, bigger instance (it refuses a box with less than 3.5 GB of memory: that is the old one)
#   2. backs up the v1 setup once (~/backups/gamenest-v1-original: compose file, Caddyfile, .env, the arcade folder, ~/data), and the
#      Caddyfile and .env again on every run
#   3. fetches the 16 game servers and the wallet from GitHub at their pinned commits (pins.txt) into ~/gamenest-v2/src; the v1 clones
#      in ~ are not touched, and each v1 commit the box runs must be an ancestor of its v2 commit
#   4. makes the data folders (empty, one per server, ~/data/<slug>) and the wallet's secret folders (~/secrets/gamenest-v2, 0700)
#   5. builds every image while v1 keeps running
#   6. starts the wallet, publishes its PUBLIC key for the rooms, swaps the seven v1 games to v2 and starts the nine new ones
#   7. puts the v2 routes into the Caddyfile's :80 block (checked by Caddy first) and reloads Caddy; adds the overlay to ~/arcade/.env
#   8. smoke test through Caddy (every /<slug>/socket.io answers, the wallet's health, the private routes are 404, the gamenestapp.com
#      sockets v1 apps use), then memory
# Nobody reaches this instance until the static IP is moved to it, so nothing here touches a player.
# Run it (the owner's one paste, from OWNER_STEPS.md):  bash ~/gamenest-v2/kit/box_deploy.sh
set -Eeuo pipefail
umask 022
export GIT_TERMINAL_PROMPT=0
HOME_DIR=/home/ubuntu
ROOT=$HOME_DIR/gamenest-v2
KIT=$ROOT/kit
ARCADE=$HOME_DIR/arcade
DATA=$HOME_DIR/data
SECRETS=$HOME_DIR/secrets/gamenest-v2
BACKUPS=$HOME_DIR/backups
ORIG=$BACKUPS/gamenest-v1-original
LOG=$ROOT/deploy.log
STATUS=$ROOT/deploy.status
OVERLAY=$KIT/compose/docker-compose.v2.yml
GH=https://github.com/cgarika
V1_SERVICES="ludo snakes eights rummy mafia spies punch"
GAME_SERVICES="ludo snakes eights rummy mafia spies punch golf four chess bowling brawl carrom soccer pool poker"
NEW_SERVICES="golf four chess bowling brawl carrom soccer pool poker wallet"

# ---- run detached, so a closed browser tab never stops a deploy halfway; the terminal follows the log ----
if [ -z "${GN_DETACHED:-}" ]; then
  mkdir -p "$ROOT"
  if [ -e "$ROOT/deploy.lock" ] && kill -0 "$(cat "$ROOT/deploy.lock" 2>/dev/null)" 2>/dev/null; then
    echo "A deploy is already running (pid $(cat "$ROOT/deploy.lock")). Following its log; Ctrl+C stops only this view."; tail -n 50 -f "$LOG"; exit 0
  fi
  [ -s "$LOG" ] && mv -f "$LOG" "$LOG.prev"; : > "$LOG"; rm -f "$STATUS"
  GN_DETACHED=1 setsid nohup bash "$0" "$@" >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$ROOT/deploy.lock"
  echo "Deploy started (pid $!). If this window closes, it keeps going: open a terminal again and run  tail -f ~/gamenest-v2/deploy.log"
  tail -n +1 --pid="$!" -f "$LOG" || true
  echo; cat "$STATUS" 2>/dev/null || echo "The deploy stopped without a result line; see ~/gamenest-v2/deploy.log"
  grep -q '^DEPLOY OK' "$STATUS" 2>/dev/null
  exit $?
fi

STEP="starting"
step() { STEP="$1"; echo; echo "== $(date -u '+%H:%M:%S') $1"; }
say() { echo "   $*"; }
stop() { echo; echo "STOPPED at: $STEP"; echo "   $*"; echo "DEPLOY STOPPED at: $STEP. $*" > "$STATUS"; rm -f "$ROOT/deploy.lock"; exit 1; }
trap 'rc=$?; if [ $rc -ne 0 ] && [ ! -s "$STATUS" ]; then echo; echo "STOPPED at: $STEP (a command failed, exit $rc; the lines above say which)"; echo "DEPLOY STOPPED at: $STEP (exit $rc)" > "$STATUS"; fi; rm -f "$ROOT/deploy.lock"' EXIT
DC() { docker compose --project-directory "$ARCADE" -f "$ARCADE/docker-compose.yml" -f "$OVERLAY" "$@"; }
DC1() { docker compose --project-directory "$ARCADE" -f "$ARCADE/docker-compose.yml" "$@"; }
pin() { awk -v s="$1" -v f="$2" '$1==s {print $f}' "$KIT/pins.txt"; }   # field 2 repo, 3 commit, 4 branch

echo "GameNest 2.0 deploy, kit $(git -C "$KIT" rev-parse --short HEAD 2>/dev/null || echo '?'), $(date -u '+%Y-%m-%d %H:%M UTC') on $(hostname)"

# ---------------------------------------------------------------------------------------------------------------------------------
step "1/8 checking this is the new instance"
[ "$(id -un)" = ubuntu ] || stop "Run this as the ubuntu user (the Lightsail browser terminal logs in as ubuntu)."
[ -f "$KIT/pins.txt" ] && [ -f "$OVERLAY" ] && [ -f "$KIT/compose/v2_routes.caddy" ] || stop "The kit is incomplete in $KIT; paste the one-line fetch again."
mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
[ "$mem_mb" -ge 3500 ] || stop "This instance has $mem_mb MB of memory: it looks like the OLD box. Nothing was changed. Open the NEW instance's terminal instead."
say "memory: $mem_mb MB"; [ "$mem_mb" -ge 7000 ] || say "WARNING: under 7 GB. The plan is 8 GB: with every game's chat filter loaded v2 needs about 6 GB at a busy moment (local_test.md)."
docker info >/dev/null 2>&1 || stop "Docker does not answer for the ubuntu user (docker info failed)."
docker compose version >/dev/null 2>&1 || stop "docker compose (v2) is missing."
say "$(docker --version | cut -d, -f1), $(docker compose version | head -1)"
[ -f "$ARCADE/docker-compose.yml" ] || stop "$ARCADE/docker-compose.yml is missing: is this the copy of the old box?"
free_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 12 ] || stop "Only ${free_gb} GB free on /. If the disk did not grow with the bigger plan: sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/nvme0n1p1 (lsblk shows the names), then run this again."
say "disk: ${free_gb} GB free"
for u in https://github.com https://huggingface.co https://registry.npmjs.org https://pypi.org https://download.pytorch.org/whl/cpu/ https://registry-1.docker.io/v2/; do
  c=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$u" || true); [ "$c" != 000 ] || stop "No answer from $u (internet)."
done
say "internet: GitHub, Hugging Face, npm, PyPI, PyTorch, Docker Hub answer"
if [ -z "$(swapon --show --noheadings 2>/dev/null)" ]; then
  say "no swap: adding a 2 GB swap file (a cushion, never the plan)"
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi
say "swap: $(swapon --show --noheadings --bytes 2>/dev/null | awk '{s+=$3} END {printf "%d MB", s/1048576}')"
# What the box's own compose file has (names, build folders and mounts only: no environment values are read out)
# (piped straight into python: the rendered config holds .env's values, so it is never written to disk or shown)
FACTS_PY=$(cat <<'PY'
import json, sys
d = json.load(sys.stdin); s = d.get("services", {})
v1, new = sys.argv[1].split(), sys.argv[2].split()
miss = [x for x in v1 + ["caddy"] if x not in s]
if miss: print("missing services in the box's compose file: " + " ".join(miss), file=sys.stderr); sys.exit(1)
clash = [x for x in new if x in s]
if clash: print("the box's compose file already has services named " + " ".join(clash) + "; the kit would change them", file=sys.stderr); sys.exit(1)
off = [x for x in v1 + ["caddy", "push"] if x in s and "default" not in (s[x].get("networks") or {"default": None})]
if off: print("these services are not on the project's default network, where the new ones go: " + " ".join(off), file=sys.stderr); sys.exit(1)
cf = [v.get("source") for v in s["caddy"].get("volumes", []) if v.get("target") == "/etc/caddy/Caddyfile" and v.get("type", "bind") == "bind"]
if len(cf) != 1: print("caddy does not mount one file at /etc/caddy/Caddyfile", file=sys.stderr); sys.exit(1)
print("CADDYFILE=" + cf[0])
print("PROJECT=" + str(d.get("name", "")))
for x in v1:
    b = s[x].get("build") or {}
    print(f"V1CTX_{x}=" + (b.get("context", "") if isinstance(b, dict) else str(b)))
PY
)
DC1 config --format json 2>/dev/null | python3 -c "$FACTS_PY" "$V1_SERVICES" "$NEW_SERVICES" > "$ROOT/.v1facts" || stop "The box's compose file is not what the kit expects (the line above says why), or docker compose cannot read it."
CADDYFILE=$(sed -n 's/^CADDYFILE=//p' "$ROOT/.v1facts"); PROJECT=$(sed -n 's/^PROJECT=//p' "$ROOT/.v1facts")
[ -f "$CADDYFILE" ] || stop "Caddy's Caddyfile ($CADDYFILE) is not a file on this box."
say "compose project '$PROJECT': caddy, the seven v1 games and the rest found; Caddy reads $CADDYFILE"
DC1 ps --status running --services 2>/dev/null | grep -qx caddy || stop "The caddy container is not running (docker compose ps)."
bash "$KIT/caddy_merge.sh" "$CADDYFILE" "$KIT/compose/v2_routes.caddy" > /dev/null || stop "could not find exactly one ':80 {' block in $CADDYFILE; nothing was changed. Ask the lead."
say "the Caddyfile has the one ':80' block the v2 routes go into"

# ---------------------------------------------------------------------------------------------------------------------------------
step "2/8 backing up v1"
sudo install -d -o ubuntu -g ubuntu -m 700 "$BACKUPS"
if [ ! -f "$ORIG/DONE" ]; then
  sudo rm -rf "$ORIG.partial"; sudo install -d -o ubuntu -g ubuntu -m 700 "$ORIG.partial"
  sudo cp -p "$ARCADE/docker-compose.yml" "$CADDYFILE" "$ORIG.partial/"
  [ -f "$ARCADE/.env" ] && sudo cp -p "$ARCADE/.env" "$ORIG.partial/dot-env"
  sudo tar czf "$ORIG.partial/arcade-folder.tgz" -C "$HOME_DIR" arcade
  [ -d "$DATA" ] && sudo tar czf "$ORIG.partial/data-folder.tgz" -C "$HOME_DIR" data
  { echo "v1 as it was on $(date -u '+%Y-%m-%d %H:%M UTC'), before GameNest 2.0"; echo "Caddyfile came from: $CADDYFILE"
    echo "--- containers"; docker compose --project-directory "$ARCADE" -f "$ARCADE/docker-compose.yml" ps --format '{{.Service}} {{.Image}} {{.Status}}' 2>/dev/null
    echo "--- v1 commits"; for sv in $V1_SERVICES; do c=$(sed -n "s/^V1CTX_$sv=//p" "$ROOT/.v1facts"); echo "$sv $c $(git -C "$c" rev-parse HEAD 2>/dev/null)"; done
    echo "--- images"; docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedSince}}'; } | sudo tee "$ORIG.partial/MANIFEST.txt" >/dev/null
  sudo chown -R ubuntu:ubuntu "$ORIG.partial"; sudo chmod -R go-rwx "$ORIG.partial"
  touch "$ORIG.partial/DONE"; mv "$ORIG.partial" "$ORIG"
  say "saved the v1 setup in $ORIG ($(du -sh "$ORIG" | cut -f1))"
else
  say "the v1 original is already saved in $ORIG (from $(stat -c %y "$ORIG/DONE" | cut -d. -f1)); kept as it is"
fi
RUN=$BACKUPS/gamenest-run-$(date -u '+%Y%m%d-%H%M%S'); install -d -m 700 "$RUN"
sudo cp -p "$CADDYFILE" "$RUN/"; [ -f "$ARCADE/.env" ] && sudo cp -p "$ARCADE/.env" "$RUN/dot-env"; sudo chown -R ubuntu:ubuntu "$RUN"
say "this run's Caddyfile and .env: $RUN"

# ---------------------------------------------------------------------------------------------------------------------------------
step "3/8 fetching the servers at their pinned commits"
mkdir -p "$ROOT/src"
while read -r svc repo commit branch _; do
  case "$svc" in ""|\#*) continue;; esac
  d=$ROOT/src/$repo
  [ -d "$d/.git" ] || git clone -q --no-checkout "$GH/$repo.git" "$d" || stop "could not clone $GH/$repo (is it on GitHub, public, with branch $branch?)"
  git -C "$d" fetch -q origin "$branch" || stop "could not fetch branch $branch of $GH/$repo"
  git -C "$d" cat-file -e "$commit^{commit}" 2>/dev/null || stop "$repo: commit $commit is not on GitHub's branch $branch"
  git -C "$d" -c advice.detachedHead=false checkout -q --force --detach "$commit"
  git -C "$d" clean -qffdx
  [ "$(git -C "$d" rev-parse HEAD)" = "$commit" ] || stop "$repo is not at $commit"
  say "$(printf '%-17s %s' "$repo" "${commit:0:12}")"
done < "$KIT/pins.txt"
say "v1's code is in v2's history (what v1 apps talk to stays compatible):"
for sv in $V1_SERVICES; do
  c=$(sed -n "s/^V1CTX_$sv=//p" "$ROOT/.v1facts"); repo=$(pin "$sv" 2); commit=$(pin "$sv" 3)
  v1=$(git -C "$c" rev-parse HEAD 2>/dev/null) || stop "$sv: $c is not a git clone; cannot check v1's commit"
  dirty=$(git -C "$c" status --porcelain --untracked-files=no 2>/dev/null | wc -l)
  if git -C "$ROOT/src/$repo" cat-file -e "$v1^{commit}" 2>/dev/null && git -C "$ROOT/src/$repo" merge-base --is-ancestor "$v1" "$commit"; then
    say "$(printf '%-17s v1 %s is an ancestor of v2 %s' "$repo" "${v1:0:7}" "${commit:0:7}")$([ "$dirty" = 0 ] || echo ", but $dirty file(s) were edited by hand on the box")"
    [ "$dirty" = 0 ] || [ "${ACCEPT_V1_DRIFT:-}" = 1 ] || stop "$c has $dirty hand-edited file(s) v2 does not carry (git -C $c status). Ask the lead; ACCEPT_V1_DRIFT=1 goes on anyway."
  else
    [ "${ACCEPT_V1_DRIFT:-}" = 1 ] || stop "$repo: the box runs $v1, which is not in v2's history. Ask the lead; ACCEPT_V1_DRIFT=1 goes on anyway."
    say "$repo: v1 ${v1:0:7} is NOT an ancestor (ACCEPT_V1_DRIFT=1 given)"
  fi
done

# ---------------------------------------------------------------------------------------------------------------------------------
step "4/8 data and secret folders"
sudo install -d -o ubuntu -g ubuntu -m 755 "$DATA" 2>/dev/null || sudo install -d -m 755 "$DATA"
for slug in ludo snakes eights rummy mafia spies punchlines golf four chess bowling brawl carrom soccer pool poker wallet wallet-backups; do
  d=$DATA/$slug
  if [ -d "$d" ] && [ ! -f "$d/.gamenest-v2" ] && [ -n "$(sudo ls -A "$d" 2>/dev/null)" ]; then stop "$d already holds files that are not v2's; nothing was moved. Ask the lead."; fi
  sudo install -d -o 1000 -g 1000 -m 700 "$d"; sudo touch "$d/.gamenest-v2"; sudo chown 1000:1000 "$d/.gamenest-v2"
done
say "$DATA/<slug> for the 16 servers, the wallet and its backups (owner uid 1000, the images' node user)"
for s in wallet appstore play; do sudo install -d -o 1000 -g 1000 -m 700 "$SECRETS/$s"; done
sudo chmod 700 "$SECRETS"
say "$SECRETS/{wallet,appstore,play}: 0700; the wallet makes its own keys in wallet/ on first start; appstore/ and play/ stay empty until the owner adds keys (the wallet is dormant for purchases until then)"
install -d -m 755 "$ROOT/public"
say "$ROOT/public: the wallet's PUBLIC key for the rooms"

# ---------------------------------------------------------------------------------------------------------------------------------
step "5/8 building the images (v1 keeps running; 10 to 20 minutes the first time)"
docker build -q -t gamenest-v2/base:current -f "$KIT/docker/base.Dockerfile" "$KIT/docker" >/dev/null || stop "the base image did not build"
docker run --rm gamenest-v2/base:current node -e "require('onnxruntime-node');console.log('base image: Node '+process.version+', onnxruntime-node and the models load')" | sed 's/^/   /'
build_rc=0; COMPOSE_PARALLEL_LIMIT=3 DC build $GAME_SERVICES wallet > "$ROOT/build.log" 2>&1 || build_rc=$?
if [ $build_rc -ne 0 ]; then tail -30 "$ROOT/build.log" | sed 's/^/   /'; stop "docker compose build failed (the full log: $ROOT/build.log)"; fi
for svc in $GAME_SERVICES wallet; do
  img=$(DC config --images 2>/dev/null | grep "^gamenest-v2/$svc:" | head -1)
  [ -n "$img" ] && docker image inspect "$img" >/dev/null 2>&1 || stop "the image for $svc was not built (docker compose build $svc shows why)"
done
say "17 images built: $(docker images --format '{{.Repository}}' | grep -c '^gamenest-v2/') gamenest-v2 images on the box"
if docker run --rm --entrypoint test "$(DC config --images | grep '^gamenest-v2/chess:')" -s /app/engine/maia2_rapid.onnx; then say "chess: the Maia-2 bots' model is in the image"
else say "WARNING: chess has no Maia-2 model (its export failed in the build); the free chess bots play the old engine until the lead fixes it"; fi

# ---------------------------------------------------------------------------------------------------------------------------------
step "6/8 the Caddyfile, checked by Caddy before anything is switched"
NEWCF=$ROOT/Caddyfile.new
bash "$KIT/caddy_merge.sh" "$CADDYFILE" "$KIT/compose/v2_routes.caddy" > "$NEWCF" || stop "could not find exactly one ':80 {' block in $CADDYFILE; nothing was changed. Ask the lead."
cid=$(DC1 ps -q caddy)
docker cp "$NEWCF" "$cid:/tmp/Caddyfile.gn2" >/dev/null
docker exec "$cid" caddy validate --config /tmp/Caddyfile.gn2 --adapter caddyfile >/dev/null 2>"$ROOT/.caddy_validate.err" || { tail -5 "$ROOT/.caddy_validate.err"; stop "Caddy says the new Caddyfile is not valid (above); nothing was switched."; }
say "Caddy says the new Caddyfile is valid ($(grep -c 'reverse_proxy' "$NEWCF") routes; the box's own lines are unchanged)"
DC config --format json | python3 -c "import json,sys; s=json.load(sys.stdin)['services']; bad=[n for n,x in s.items() if 'TEST_HOOKS' in (x.get('environment') or {})]; print('   TEST_HOOKS: '+('SET ON '+' '.join(bad) if bad else 'absent everywhere')); sys.exit(1 if bad else 0)" || stop "TEST_HOOKS must never be set in production"

# ---------------------------------------------------------------------------------------------------------------------------------
step "7/8 switching: the wallet, then the 16 game servers, then Caddy"
DC up -d --no-build wallet 2>&1 | sed 's/^/   /'
for i in $(seq 1 60); do curl -s -m 3 http://127.0.0.1:3920/wallet/health | grep -q '"ok":true' && break; sleep 1; done
curl -s -m 3 http://127.0.0.1:3920/wallet/health | grep -q '"ok":true' || stop "the wallet does not answer on 127.0.0.1:3920 (docker compose logs wallet)"
say "wallet: $(curl -s -m 3 http://127.0.0.1:3920/wallet/health | grep -o '"schema":[0-9]*\|"apple":{"ready":[a-z]*' | tr '\n' ' ')"
DC exec -T wallet node tools/export_pubkeys.js --out /pub/wallet_pubkeys.json | sed 's/^/   /'
[ -s "$ROOT/public/wallet_pubkeys.json" ] || stop "the wallet's public key was not written to $ROOT/public"
DC up -d --no-build $GAME_SERVICES 2>&1 | sed 's/^/   /'
for svc in $GAME_SERVICES; do
  case $svc in punch) base=/punchlines;; *) base=/$svc;; esac
  ok=""
  for i in $(seq 1 90); do
    if DC exec -T "$svc" node -e "fetch('http://127.0.0.1:3000$base/socket.io/?EIO=4&transport=polling').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  [ -n "$ok" ] || stop "$svc does not answer at $base inside its container (docker compose logs $svc)"
done
say "16 game servers answer inside their containers"
sudo tee "$CADDYFILE" < "$NEWCF" > /dev/null   # in place: the same file Caddy's container has mounted
if docker exec "$cid" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then say "Caddy reloaded with the v2 routes (no restart)"
else DC1 restart caddy >/dev/null 2>&1 && say "Caddy restarted with the v2 routes"; fi
line="COMPOSE_FILE=docker-compose.yml:$OVERLAY"
if ! sudo grep -qxF "$line" "$ARCADE/.env" 2>/dev/null; then
  printf '\n# GameNest 2.0 (box_deploy.sh): docker compose in this folder also reads the v2 overlay\n%s\n' "$line" | sudo tee -a "$ARCADE/.env" >/dev/null
fi
say "~/arcade/.env names the overlay: 'docker compose ps' / 'logs <service>' in ~/arcade see all of v2"

# ---------------------------------------------------------------------------------------------------------------------------------
step "8/8 smoke test through Caddy, and memory"
sleep 2
bash "$KIT/smoke.sh" box || stop "the smoke test failed (above). Players are not affected yet: the IP has not moved. Ask the lead."
echo; free -m | sed 's/^/   /'
echo; docker stats --no-stream --format '{{.Name}}: {{.MemUsage}}' | sort | sed 's/^/   /'
echo "DEPLOY OK $(date -u '+%Y-%m-%d %H:%M UTC'): GameNest 2.0 runs on this instance (kit $(git -C "$KIT" rev-parse --short HEAD)). Next: move the static IP (OWNER_STEPS.md)." | tee "$STATUS"
