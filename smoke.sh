#!/usr/bin/env bash
# Smoke: CLI (bucket/put/get/rm/ls, dedup + refcounted delete) + HTTP API
# (auth, PUT/GET/HEAD/DELETE/list, 401/404). Builds first so this always
# tests the binary that would actually ship.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

DATA=$(mktemp -d /tmp/machin-esetres-smoke-XXXX)
BIN="./machin-esetres -d $DATA"
PORT=19034
FILE=$(mktemp /tmp/machin-esetres-smoke-file-XXXX)
echo "hello attachment bytes" > "$FILE"
WANT_SHA=$(sha256sum "$FILE" | cut -d' ' -f1)

cleanup() { kill "${SERVER_PID:-0}" 2>/dev/null || true; rm -rf "$DATA" "$FILE" "$OUTFILE" "$OUTFILE2" 2>/dev/null || true; }
trap cleanup EXIT

# ---- CLI: bucket create, help-json ----
out=$($BIN help-json); grep -q '"tool":"machin-esetres"' <<<"$out"
out=$($BIN bucket create mymailbox); grep -q '"ok":true' <<<"$out"
TOKEN=$(echo "$out" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
test -n "$TOKEN"

# ---- CLI: put / ls / get, and content survives the round-trip ----
out=$($BIN put mymailbox "att/1/invoice.pdf" "$FILE" --content-type application/pdf)
grep -q "\"sha256\":\"$WANT_SHA\"" <<<"$out"
out=$($BIN ls mymailbox); grep -q '"key":"att/1/invoice.pdf"' <<<"$out"
OUTFILE=$(mktemp /tmp/machin-esetres-smoke-out-XXXX)
$BIN get mymailbox "att/1/invoice.pdf" --to "$OUTFILE" >/dev/null
diff "$FILE" "$OUTFILE"

# ---- CLI: dedup — same bytes under a second key share one blob ----
$BIN put mymailbox "att/2/copy.pdf" "$FILE" --content-type application/pdf >/dev/null
SHARD="$DATA/mymailbox/objects/${WANT_SHA:0:2}/${WANT_SHA:2:2}/$WANT_SHA"
test -f "$SHARD"
$BIN rm mymailbox "att/1/invoice.pdf" >/dev/null
test -f "$SHARD"   # refcount 2 -> 1: blob must survive the first delete
$BIN rm mymailbox "att/2/copy.pdf" >/dev/null
test ! -f "$SHARD" # refcount 1 -> 0: blob must be gone after the second

# ---- CLI: not-found is exit 90, not a crash ----
set +e
$BIN get mymailbox nosuchkey --to "$OUTFILE" >/dev/null 2>/tmp/machin-esetres-smoke-err
code=$?
set -e
test "$code" = "90"
grep -q '"ok":false' /tmp/machin-esetres-smoke-err
rm -f /tmp/machin-esetres-smoke-err

# ---- HTTP: auth, PUT/GET/HEAD/DELETE/list, 401/404 ----
out=$($BIN bucket create httptest); TOKEN2=$(echo "$out" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
$BIN serve --port $PORT >/tmp/machin-esetres-smoke-server.log 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 40); do curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS "http://127.0.0.1:$PORT/healthz" | grep -q '"ok":true'

code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --data-binary @"$FILE" "http://127.0.0.1:$PORT/b/httptest/o/hello.txt")
test "$code" = "401"   # no token
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer wrong" --data-binary @"$FILE" "http://127.0.0.1:$PORT/b/httptest/o/hello.txt")
test "$code" = "401"   # wrong token
out=$(curl -sf -X PUT -H "Authorization: Bearer $TOKEN2" -H "Content-Type: text/plain" --data-binary @"$FILE" "http://127.0.0.1:$PORT/b/httptest/o/hello.txt")
grep -q "\"sha256\":\"$WANT_SHA\"" <<<"$out"

OUTFILE2=$(mktemp /tmp/machin-esetres-smoke-out2-XXXX)
curl -sf -H "Authorization: Bearer $TOKEN2" "http://127.0.0.1:$PORT/b/httptest/o/hello.txt" -o "$OUTFILE2"
diff "$FILE" "$OUTFILE2"

out=$(curl -sf -H "Authorization: Bearer $TOKEN2" -X HEAD "http://127.0.0.1:$PORT/b/httptest/o/hello.txt")
grep -q "\"size\":$(stat -c%s "$FILE")" <<<"$out"

out=$(curl -sf -H "Authorization: Bearer $TOKEN2" "http://127.0.0.1:$PORT/b/httptest?prefix=hel")
grep -q '"key":"hello.txt"' <<<"$out"

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/b/nosuchbucket/o/x")
test "$code" = "404"

curl -sf -X DELETE -H "Authorization: Bearer $TOKEN2" "http://127.0.0.1:$PORT/b/httptest/o/hello.txt" | grep -q '"deleted":true'
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN2" "http://127.0.0.1:$PORT/b/httptest/o/hello.txt")
test "$code" = "404"

echo "OK machin-esetres smoke"
