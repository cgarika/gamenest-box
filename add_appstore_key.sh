#!/bin/bash
# GameNest 2.0: give the wallet Apple's In-App Purchase key, so App Store purchases are credited (lead, 2026-11-16).
# The owner runs this ON the box, in the Lightsail browser terminal, once:
#     bash ~/gamenest-v2/kit/add_appstore_key.sh <KEY_ID>
# <KEY_ID> is the 10 letters and digits in the downloaded file's name (SubscriptionKey_<KEY_ID>.p8, or AuthKey_<KEY_ID>.p8).
# Then paste the whole file (from -----BEGIN PRIVATE KEY----- to -----END PRIVATE KEY-----), press Enter, then Ctrl+D.
# The key goes into ~/secrets/gamenest-v2/appstore/ (0700, readable only by the wallet's user); it is never printed, and this script
# never shows it again. The wallet is restarted and its health must then say "apple ready true".
set -euo pipefail
KEY_ID=${1:-}
ISSUER=a5ef5957-ef2c-432f-8543-d720a055b8c4     # the team's issuer id (not a secret: it names the team)
DIR=/home/ubuntu/secrets/gamenest-v2/appstore
[[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "Give the key's ID: bash ~/gamenest-v2/kit/add_appstore_key.sh ABCDE12345"; exit 1; }
echo "Paste the key now (all of it, BEGIN to END), press Enter, then Ctrl+D:"
PEM=$(cat)
grep -q -- "-----BEGIN PRIVATE KEY-----" <<<"$PEM" && grep -q -- "-----END PRIVATE KEY-----" <<<"$PEM" || { echo "That was not the whole key (BEGIN and END lines are needed). Nothing was saved."; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$PEM" > "$TMP/SubscriptionKey_$KEY_ID.p8"
printf '{"keyId":"%s","issuerId":"%s","keyFile":"SubscriptionKey_%s.p8"}\n' "$KEY_ID" "$ISSUER" "$KEY_ID" > "$TMP/appstore.json"
openssl pkey -in "$TMP/SubscriptionKey_$KEY_ID.p8" -noout 2>/dev/null || { echo "That key could not be read (a character may be missing). Nothing was saved."; exit 1; }
sudo install -d -o 1000 -g 1000 -m 700 "$DIR"
sudo find "$DIR" -maxdepth 1 -name '*.p8' -delete
sudo install -o 1000 -g 1000 -m 600 "$TMP/SubscriptionKey_$KEY_ID.p8" "$DIR/"
sudo install -o 1000 -g 1000 -m 600 "$TMP/appstore.json" "$DIR/"
echo "Saved. Restarting the wallet..."
cd /home/ubuntu/arcade && docker compose --project-directory /home/ubuntu/arcade -f docker-compose.yml -f /home/ubuntu/gamenest-v2/kit/compose/docker-compose.v2.yml restart wallet >/dev/null
for i in $(seq 1 30); do
  H=$(curl -s -m 5 -H "Host: needasix.com" http://127.0.0.1/wallet/health || true)
  if grep -q '"apple":{"ready":true' <<<"$H"; then echo "KEY OK: the wallet reaches Apple (apple ready true)."; exit 0; fi
  sleep 2
done
echo "The wallet restarted but does not say apple ready yet. Send the lead this line: $(grep -o '"apple":{[^}]*}' <<<"$H" || echo no health answer)"
exit 1
