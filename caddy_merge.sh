#!/bin/bash
# Puts GameNest 2.0's routes at the top of the box's own ":80 { ... }" site block and changes nothing else in the Caddyfile
# (gamenestapp.com, its /<game>/socket.io routes for v1 apps, the arcade page, push, feedback: all kept as they are).
#   caddy_merge.sh <current Caddyfile> <v2_routes.caddy>  > <new Caddyfile>
# Re-runnable: lines between the ">>> GameNest 2.0 routes" and "<<< GameNest 2.0 routes" markers (from an earlier run) are replaced.
# Exits 2 (and prints nothing on stdout) unless there is exactly one top-level ":80 {" line (also "http://:80 {").
set -euo pipefail
old=$1 routes=$2
[ -s "$old" ] && [ -s "$routes" ] || { echo "caddy_merge: missing input" >&2; exit 2; }
out=$(awk -v routes="$routes" '
  function strip(s) { sub(/(^|[ \t])#.*$/, "", s); return s }          # a comment never counts towards the braces
  BEGIN { depth = 0; found = 0; skipping = 0 }
  {
    line = $0
    if (skipping) { if (line ~ /<<< GameNest 2\.0 routes <<</) skipping = 0; next }
    if (line ~ />>> GameNest 2\.0 routes/) { skipping = 1; next }        # an earlier run: dropped here, written again after ":80 {"
    s = strip(line)
    if (depth == 0 && s ~ /^[ \t]*(http:\/\/)?:80[ \t]*\{[ \t]*$/) {
      print line; found++
      while ((getline r < routes) > 0) print r
      close(routes)
      depth++
      next
    }
    print line
    o = gsub(/\{/, "{", s); c = gsub(/\}/, "}", s); depth += o - c
    if (depth < 0) { print "caddy_merge: unbalanced braces" > "/dev/stderr"; exit 3 }
  }
  END { if (found != 1) { print "caddy_merge: found " found " top-level :80 blocks, want exactly 1" > "/dev/stderr"; exit 2 }
        if (depth != 0) { print "caddy_merge: braces do not balance at the end" > "/dev/stderr"; exit 3 } }
' "$old")
printf '%s\n' "$out"
