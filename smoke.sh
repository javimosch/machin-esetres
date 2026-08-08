#!/usr/bin/env bash
# Smoke: CLI (bucket/put/get/rm/ls, dedup + refcounted delete) + Phase 1 HTTP
# API (auth, PUT/GET/HEAD/DELETE/list, 401/404) + Phase 2 S3 facade against a
# REAL aws-cli (SigV4 signing done by an independent implementation, not our
# own signer testing our own verifier — skipped if aws-cli isn't installed).
# Builds first so this always tests the binary that would actually ship.
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

# ---- Phase 2: the S3 facade, driven by a REAL aws-cli (independent SigV4) ----
if command -v aws >/dev/null 2>&1; then
    out=$($BIN bucket create s3test); TOKEN3=$(echo "$out" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    export AWS_ACCESS_KEY_ID=s3test
    export AWS_SECRET_ACCESS_KEY="$TOKEN3"
    export AWS_DEFAULT_REGION=us-east-1
    ENDPOINT="http://127.0.0.1:$PORT"

    aws --endpoint-url "$ENDPOINT" s3 cp "$FILE" s3://s3test/hello.txt >/dev/null
    aws --endpoint-url "$ENDPOINT" s3 ls s3://s3test/ | grep -q hello.txt
    OUTFILE3=$(mktemp /tmp/machin-esetres-smoke-out3-XXXX)
    aws --endpoint-url "$ENDPOINT" s3 cp s3://s3test/hello.txt "$OUTFILE3" >/dev/null
    diff "$FILE" "$OUTFILE3"
    rm -f "$OUTFILE3"

    aws --endpoint-url "$ENDPOINT" s3api head-object --bucket s3test --key hello.txt | grep -q '"ContentLength"'

    set +e
    AWS_SECRET_ACCESS_KEY=wrongsecret aws --endpoint-url "$ENDPOINT" s3 ls s3://s3test/ >/dev/null 2>/tmp/machin-esetres-smoke-awserr
    wrong_code=$?
    set -e
    test "$wrong_code" != "0"
    grep -q SignatureDoesNotMatch /tmp/machin-esetres-smoke-awserr
    rm -f /tmp/machin-esetres-smoke-awserr

    aws --endpoint-url "$ENDPOINT" s3 rm s3://s3test/hello.txt >/dev/null
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    echo "OK machin-esetres smoke (Phase 1 + Phase 2 / real aws-cli)"
else
    echo "OK machin-esetres smoke (Phase 1 only — aws-cli not installed, Phase 2 skipped)"
fi
