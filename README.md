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

**Phase 1 is built and passing its smoke test** (`./smoke.sh`): buckets,
sha256-deduped objects with refcounted delete, bearer-token HTTP API
(PUT/GET/HEAD/DELETE + prefix list), and the CLI, all in one native binary.
Not yet deployed to rbm21 or wired into poche-resend-webmail — see
[AGENTS.md](AGENTS.md) for the open questions and next steps.

## The plan, in short

- **Phase 1 — custom REST + CLI. Done.** Bucket/key object model, bearer-token
  auth (the same pattern poche-resend-webmail already uses), agent-first JSON
  responses, built directly on `machweb.src` (machin's existing HTTP framework
  — binary-safe request bodies, streaming responses, routing; no new framework
  needed). Fixes the actual problem: attachments get a real API, sha256-based
  dedup, and a host independent of poche-resend-webmail's own disk.
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

## API (Phase 1 — as built)

```
PUT    /b/<bucket>/o/<key>        upload — body is the raw bytes
GET    /b/<bucket>/o/<key>        download
HEAD   /b/<bucket>/o/<key>        JSON metadata (not a bodyless response — see AGENTS.md)
DELETE /b/<bucket>/o/<key>        delete (refcount-aware)
GET    /b/<bucket>?prefix=<p>     list, JSON: {"ok":true,"items":[...]}  (no pagination cursor yet)
GET    /healthz                   health
```

Auth: `Authorization: Bearer <token>`, one token per bucket — same shape as
poche-resend-webmail's own `WEBMAIL_TOKEN`/`ADMIN_TOKEN`, nothing new to learn.

Bucket creation/deletion is **CLI-only** in Phase 1, not an HTTP route — one
less auth concept (no separate admin token) for a decision that doesn't need
to happen over the network.

## CLI (Phase 1 — as built)

Same agent-first contract as machin-vault: `{"version":"1","ok":true,...}` on
stdout, errors on stderr in the same envelope, semantic exit-code bands,
`help-json` for self-description.

```bash
machin-esetres -d <data-dir> bucket create <name>   # prints the token — shown once, here only
machin-esetres -d <data-dir> bucket list
machin-esetres -d <data-dir> put <bucket> <key> <file> [--content-type <ct>]
machin-esetres -d <data-dir> get <bucket> <key> --to <file>
machin-esetres -d <data-dir> rm <bucket> <key>
machin-esetres -d <data-dir> ls <bucket> [--prefix p]
machin-esetres -d <data-dir> serve --port 9000
machin-esetres help-json
```

`put`/`get` take real file paths only in Phase 1 (no `-` for stdin — see
AGENTS.md's non-goals).

### Try it

```bash
./build.sh
./machin-esetres -d ./data bucket create mymailbox     # copy the printed token
./machin-esetres -d ./data put mymailbox hello.txt ./README.md
./machin-esetres -d ./data ls mymailbox
./machin-esetres -d ./data serve --port 9000 &
curl -H "Authorization: Bearer <token>" http://localhost:9000/b/mymailbox/o/hello.txt
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
