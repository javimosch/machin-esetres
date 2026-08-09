#!/usr/bin/env bash
# Unit tests: direct calls into store.src/sigv4.src/s3.src/server.src's
# functions via constructed Request/Response structs — no live server, no
# CLI, no aws-cli (that's smoke.sh's job). See src/test.src for why
# src/main.src is deliberately excluded from this build (its own main()
# would collide with the test runner's).
set -euo pipefail
cd "$(dirname "$0")"
machin test --json framework/flags.src framework/machweb.src \
  src/store.src src/sigv4.src src/s3.src src/server.src src/test.src
