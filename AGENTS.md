# AGENTS.md — machin-esetres

Architecture notes, decisions, and open questions for whoever (human or agent)
picks this up next. This file is the source of truth for *why*, not just
*what* — keep it current as decisions get made or revisited.

## Origin

poche-resend-webmail's "Honest limitations" README section calls out: sent
attachment bytes live on the app server's local filesystem
(`blobstore.go` / `BLOB_DIR`), not in poche (poche keeps documents in memory —
6MB of base64 blob data once pushed its RSS from 4MB to 315MB, which is why
attachments were never stored *in* poche to begin with). No dedup, no HTTP
API, single host, no HA story beyond `tar czf` by hand.

Decided 2026-08-08: build a proper self-hosted object store in machin rather
than keep extending the ad hoc blob store, because (a) poche's own `_files`
collection has the identical gap — GET works, no HTTP upload route — so this
is really *two* ad hoc blob stores in the ecosystem that could be one real
service, and (b) machin already has almost all the plumbing (`machweb.src`
has binary-safe bodies, multipart parsing, streaming responses, HMAC signing;
`machin-kv` proves the SQLite-index pattern) — this is closer to "assemble
existing parts" than "build a storage engine from scratch."

## Decisions made (2026-08-08 design pass)

| Question | Decision | Why |
|---|---|---|
| API scope | Phase 1: custom REST (bucket/key, bearer token). Phase 2 (committed, not speculative): real AWS SigV4-compatible facade over the same object model. | Phase 1 fixes poche-resend-webmail's actual problem without the SigV4 lift. Phase 2 is what makes this a genuine MinIO alternative rather than "S3-flavored." Explicitly requested, not deferred indefinitely. |
| Deployment host | rbm21 (100.123.0.125 via Tailscale), not colocated with poche-resend-webmail on dk1. | Separate failure domain — the whole point of moving attachments off a single app server's disk is defeated if the object store shares that server. rbm21 already has zig/gcc for a native build. |
| Exposure | Internal only, over Tailscale. No public Traefik route. | It's a backend service other machin-ecosystem apps talk to, not something end users hit directly. |
| Tenancy | Bucket-per-mailbox. | Matches poche-resend-webmail's existing per-mailbox model (own Resend creds, own quota) — attachments for different clients (e.g. La Cure) stay cleanly separable, deletable, and backup-able independently. |
| Dedup | Content-addressed by sha256, refcounted, at the storage layer — not a feature flag, just how objects are laid out on disk. | Free win once you're building fresh rather than extending `blobstore.go`'s random-ID layout. |
| Index | SQLite per bucket (`<bucket>/index.db`), not one global DB. | Buckets stay independently movable, deletable, and backup-able as a unit — consistent with the bucket-per-mailbox tenancy decision. |

## Open questions (not yet decided — resolve before or during Phase 1)

- **Auth token issuance/rotation**: one bearer token per bucket, generated how
  (CLI command? config file at bucket-create time?), rotated how? Should
  probably mirror poche-resend-webmail's own `readSecretFlag` pattern (stdin
  or `env:NAME`, never argv) — that convention already exists in this
  ecosystem for exactly this reason.
- **poche-resend-webmail's migration path**: does `blobstore.go` get replaced
  outright (attachments only ever live in machin-esetres going forward), or
  does it become a two-tier cache (recent/hot attachments on local disk,
  everything else in machin-esetres)? Affects whether Phase 1 needs a
  bulk-migrate-existing-attachments tool from day one.
- **Backup story**: machin-esetres's own data directory is a natural
  machin-vault `file` target (rsync-based) — should it be, from day one, or is
  that a separate follow-up once the service exists and has real data?
- **rbm21 disk**: 14G free as of 2026-08-08, 76% used. Needs a dedicated
  volume/mount before this holds production attachment data — resolve before
  Phase 1 goes live with real traffic, not necessarily before Phase 1 code is
  written.
- **List pagination cursor shape**: `next` in the list response — opaque
  token backed by the SQLite index (e.g. last key + limit), or something
  S3-shaped (`ContinuationToken`) to reduce Phase 2 rework? Leaning toward the
  latter since Phase 2 is committed, not speculative — worth deciding before
  Phase 1's list endpoint is built, not after.
- **Multipart uploads for large objects**: out of scope until `machweb`
  grows streamed (not fully-buffered) request bodies — see the platform
  constraint in README.md. Not needed for mail attachments today; revisit if
  a real use case needs it (per this ecosystem's usual pattern of a real
  project driving the machin feature, not building it speculatively).

## Reference: what machin already provides (verified 2026-08-08)

Grounded by reading `~/ai/machin/framework/machweb.src` and sibling projects
directly — not assumed.

- **`machweb.src`** (`serve(port, handler)`): binary-safe request bodies
  (`body_bytes bytes`), `parse_multipart`/`multipart_file`/`multipart_field`
  for `multipart/form-data`, `header`/`query`/`param`/`cookie` accessors,
  streaming responses (`stream_response`, `sse`, `hijack` for protocol
  upgrades), HMAC-signed sessions (`session_sign`/`session_verify`,
  `set_session`/`get_session`), `serve_tls` for direct TLS (not needed here —
  Tailscale + internal-only). Request body is read fully into memory based on
  `Content-Length` — see the platform constraint above.
- **SQLite builtins** (`sqlite_open`/`sqlite_exec`/`sqlite_query`, proven in
  `machin-kv` and `machin-web-demo-users`): `sqlite_query` returns a JSON
  array, composes with `json_get`. Bound-parameter execution
  (`sqlite_exec(db, "... VALUES(?, ?)", []string{...})`) is injection-safe —
  use it for the index, not string-concatenated SQL.
- **`flags.src`** (vendored across every machin CLI in this ecosystem,
  canonical copy in `machin/framework/`): short/long flags, `=`/space value
  forms, bool flags, defaults, positionals, auto `--help`. Use it rather than
  hand-rolling argument parsing.
- **The house agent-first contract** (established by machin-vault, formalized
  further by the `agent-first-cli-specs` skill): versioned envelope
  (`{"version":"1","ok":...}`), errors on stderr in the same shape, semantic
  exit-code bands (`0` ok · `80-89` bad input · `90-99` not found · `100-109`
  integration failure · `110-119` internal), `help-json` self-description,
  destructive actions refuse without an explicit `--yes`/`--force`. Reuse
  this verbatim rather than inventing a new contract.

## Non-goals (explicit, so they don't get assumed later)

- Fixing poche-resend-webmail's *inbound* attachment gap (needs a
  read-capable Resend API key — unrelated to where sent attachments are
  stored).
- Multi-region replication, erasure coding, or anything MinIO-cluster-shaped.
  This is one binary, one data directory, on one box (rbm21) — HA here means
  "not sharing a disk with the app server and having a real backup story," not
  "distributed consensus."
- Byte-for-byte MinIO API parity in Phase 1. Phase 2's SigV4 facade targets
  "existing S3 clients work," not "every MinIO-specific extension works."
