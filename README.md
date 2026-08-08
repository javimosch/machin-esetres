# machin-esetres

*"es-tres"* — as in **S-3**, said the way this ecosystem's other name-puns work.
A self-hosted object store written in **[machin](https://github.com/javimosch/machin)**
(MFL): agent-first CLI, RESTful HTTP API, one static binary. Built to give
[poche-resend-webmail](https://github.com/javimosch/poche-resend-webmail)'s mail
attachments a real home — off one app server's local disk, deduplicated, with
an API instead of a directory convention.

Part of the [machin](https://github.com/javimosch/machin) ecosystem — sibling to
[machin-vault](https://github.com/javimosch/machin-vault) (backup/recovery) and
[machin-kv](https://github.com/javimosch/machin-kv) (key-value store), reusing the
same house style: JSON in/out, semantic exit codes, one binary that is both a CLI
and an HTTP server.

## Why it exists

poche-resend-webmail currently stores sent-attachment bytes in a hand-rolled
on-disk blob store (`blobstore.go`): random hex IDs, a 2-char sharded directory,
atomic tmp-then-rename writes — but no dedup, no HTTP API, no story for moving
attachments off the app server's disk, and no way for anything else in this
ecosystem (poche's own `_files` collection has the same gap: GET works, there's
no HTTP upload route) to share the same storage.

machin-esetres is that shared storage: a small, real object-store *service* —
buckets, keys, bytes in/out over HTTP — instead of every app reinventing a blob
directory.

## Status

**Design phase.** This README is the spec before the code. See
[AGENTS.md](AGENTS.md) for the full architecture, the phased roadmap, and the
open questions still to resolve before Phase 1 implementation starts.

## The plan, in short

- **Phase 1 — custom REST + CLI.** Bucket/key object model, bearer-token auth
  (the same pattern poche-resend-webmail already uses), agent-first JSON
  responses, built directly on `machweb.src` (machin's existing HTTP framework —
  it already has binary-safe request bodies, multipart parsing, streaming
  responses, and HMAC signing; no new framework needed to start). Fixes the
  actual problem: attachments get a real API, sha256-based dedup, and a host
  independent of poche-resend-webmail's own disk.
- **Phase 2 — a real S3-compatible facade.** AWS SigV4 request signing + the
  actual S3 REST API shape on top of the same bucket/key/object model, so
  `aws-cli`, `mc`, `rclone`, and any S3 SDK work against it unmodified — a real
  MinIO alternative, not just an S3-flavored API. Deferred behind Phase 1
  because SigV4 is a serious chunk of work and isn't needed for
  poche-resend-webmail itself, but it's a committed roadmap item, not a maybe.

## Where it runs

**rbm21** (LXC on pve2, `100.123.0.125` over Tailscale) — a separate failure
domain from dk1, where poche-resend-webmail actually runs. Reached over
Tailscale, not exposed publicly (no reason for an internal object-storage
backend to have a public hostname). `zig`/`gcc` are already present on rbm21,
so it builds there directly.

**Known constraint:** rbm21's root disk is at 76% (14G free) as of the design
pass (2026-08-08). Fine for early KB–MB attachment traffic; needs a dedicated
volume/mount before this holds real production data at any scale — a Phase 1
prerequisite, not an afterthought.

## Data model (Phase 1)

- **Bucket** = tenant boundary. One per mailbox (matches poche-resend-webmail's
  existing per-mailbox model: own Resend credentials, own quota, own bucket).
- **Object** = key (path-like string) → bytes + content-type + metadata,
  content-addressed by sha256 — two attachments with identical bytes share one
  blob on disk, for free, as a side effect of the storage layout rather than a
  feature that had to be built.

```
<data-dir>/<bucket>/objects/<sha256[0:2]>/<sha256[2:4]>/<sha256>   # the blob
<data-dir>/<bucket>/index.db                                       # SQLite: key -> {sha256, size, content_type, created_at, refcount}
```

The index is SQLite via machin's existing `sqlite_open`/`sqlite_exec`/
`sqlite_query` builtins (proven in machin-kv and the `machin-web-demo-users`
CRUD demo) — `key -> sha256` with a refcount per blob, so deleting a key
decrements the count and only unlinks the blob file at zero. Multiple keys
(even across different original filenames) can point at the same blob.

## API (Phase 1 — draft, not yet built)

```
PUT    /b/<bucket>/o/<key>        upload — body is the raw bytes
GET    /b/<bucket>/o/<key>        download
HEAD   /b/<bucket>/o/<key>        metadata only
DELETE /b/<bucket>/o/<key>        delete (refcount-aware)
GET    /b/<bucket>?prefix=<p>     list, JSON: {"ok":true,"items":[...],"next":...}
PUT    /b/<bucket>                create bucket
DELETE /b/<bucket>                delete bucket (empty only, or ?force=1)
GET    /healthz                   health
```

Auth: `Authorization: Bearer <token>`, one token per bucket — same shape as
poche-resend-webmail's own `WEBMAIL_TOKEN`/`ADMIN_TOKEN`, nothing new to learn.

## CLI (Phase 1 — draft)

Same agent-first contract as machin-vault: `{"version":"1","ok":true,...}` on
stdout, errors on stderr in the same envelope, semantic exit-code bands,
`help-json` for self-description.

```bash
machin-esetres bucket create <name>
machin-esetres put <bucket> <key> <file>       # or - for stdin
machin-esetres get <bucket> <key> [--to file]
machin-esetres rm <bucket> <key>
machin-esetres ls <bucket> [--prefix p]
machin-esetres serve --port 9000
machin-esetres help-json
```

## What this does *not* fix

Inbound mail attachment content (Resend's webhook payload carries no bytes/URL
without a read-capable API key) is a separate, already-known gap in
poche-resend-webmail — unrelated to where sent attachments are stored, and not
something an object store on the receiving end changes.

## Platform constraint worth knowing up front

`machweb.src` currently reads a request's full body into memory
(`Content-Length`-driven), not via chunked/streamed input. That's fine for mail
attachments (KB–MB, the same order of magnitude poche-resend-webmail already
handles) but rules out naive multi-GB uploads without extending the framework
first. Consistent with how this ecosystem usually grows machin — a real
project's actual need drives the feature (SQLite builtins came from
machin-kv needing persistence; `pbkdf2_sha256` came from machin-wiki needing
password hashing) — so if large-object support becomes a real requirement,
that's a machweb streaming-body feature to drive, not a machin-esetres
workaround to invent.

## Layout (once Phase 1 code exists)

```
machin-esetres/
├── esetres.src     # CLI + HTTP server (MFL)
├── flags.src       # vendored flag parser (canonical copy in machin/framework/)
├── build.sh
├── smoke.sh
├── README.md
└── AGENTS.md
```
