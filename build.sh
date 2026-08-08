#!/usr/bin/env bash
# Build machin-esetres: one native binary, both the agent-first CLI and the
# HTTP object-store server. Needs the machin compiler (framework/machweb.src +
# framework/flags.src resolve from the binary — nothing to vendor).
set -euo pipefail
cd "$(dirname "$0")"
MACHIN="${MACHIN:-machin}"
command -v "$MACHIN" >/dev/null 2>&1 || { echo "error: '$MACHIN' not found (set MACHIN=/path/to/machin)"; exit 1; }

"$MACHIN" encode \
    framework/flags.src framework/machweb.src \
    src/store.src src/sigv4.src src/s3.src src/server.src src/main.src \
    > esetres.mfl

"$MACHIN" build esetres.mfl -o machin-esetres
echo "built ./machin-esetres"
echo "cli:   ./machin-esetres help-json"
echo "serve: ./machin-esetres -d ./data serve --port 9000"
