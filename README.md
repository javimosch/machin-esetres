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

**Phase 1 and Phase 2 are both built and passing `./smoke.sh`** — including a
Phase 2 run against a genuine `aws-cli` (real independent SigV4 signing, not
our own signer testing our own verifier). Deployed and running on rbm21 (see
"Where it runs" below). **Coverage gate met**: 72.7% unit (`./test.sh`,
32/44 functions, verified real by an intentional break-and-confirm-failure
check) + 100% functional/smoke (`./smoke.sh`, 44/44 functions traced) — see
AGENTS.md's "Coverage gate" section for the full methodology, since machin
has no coverage-instrumentation tool to compute this automatically. Not yet
wired into poche-resend-webmail itself — see [AGENTS.md](AGENTS.md) for the
open questions and next steps.

## The plan, in short

- **Phase 1 — custom REST + CLI. Done.** Bucket/key object model, bearer-token
  auth (the same pattern poche-resend-webmail already uses), agent-first JSON
  responses, built directly on `machweb.src` (machin's existing HTTP framework
  — binary-safe request bodies, streaming responses, routing; no new framework
  needed). Fixes the actual problem: attachments get a real API, sha256-based
  dedup, and a host independent of poche-resend-webmail's own disk.
- **Phase 2 — a real S3-compatible facade. Done.** AWS SigV4 request
  verification (pure MFL over `hmac_sha256_bytes`/`sha256_bytes` — no new
  machin builtin needed) + path-style S3 routing + XML responses over the
  same bucket/key/object model. Verified against real `aws-cli`: `s3 cp`
  (upload + download), `s3 ls`, `s3 rm`, `s3api head-object`, and rejection of
  a wrong secret with the real `SignatureDoesNotMatch` error. See "Phase 2
  scope limits" below for what's deliberately not covered yet.

## Where it runs

**Deployed** on rbm21 (LXC on pve2, `100.123.0.125` over Tailscale) — a
separate failure domain from dk1, where poche-resend-webmail actually runs.
Systemd unit `machin-esetres.service`, static binary at
`/opt/machin-esetres/machin-esetres`, data at `/var/lib/machin-esetres/data`,
port 9000, internal-only (no public Traefik route). Health-checked from both
rbm21 itself and from dk1 over Tailscale. Full operational details —
credentials handling, rebuild/redeploy steps, service control — live in
`~/backups/machin-esetres/access.txt` (not in this repo, since it's
host-specific and gitignored-adjacent by convention in this ecosystem).

**Known constraint:** rbm21's root disk was at 76% (14G free) as of deploy
(2026-08-08). Fine for early KB–MB attachment traffic; needs a dedicated
volume/mount before this holds real production data at any scale.

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

## Phase 2 — the S3-compatible facade (as built)

Same buckets, same tokens, a second protocol front-end at path-style S3
routes (not under `/b/` — anything else is routed here):

```
PUT    /<bucket>/<key>        upload (aws s3 cp / mc cp / any SDK put_object)
GET    /<bucket>/<key>        download
HEAD   /<bucket>/<key>        see "Phase 2 scope limits" — not spec-correct
DELETE /<bucket>/<key>        delete
GET    /<bucket>?list-type=2  ListObjectsV2 XML
```

Auth is AWS SigV4: **access_key_id = bucket name, secret_access_key = the
bucket's token** (the same one `bucket create` printed). No separate
credential store — set up an `aws-cli` profile or `mc alias` with those two
values and a region of your choosing (this facade doesn't check it):

```bash
export AWS_ACCESS_KEY_ID=mymailbox
export AWS_SECRET_ACCESS_KEY=<the token>
export AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url http://<host>:9000 s3 cp ./file.pdf s3://mymailbox/attachments/1/file.pdf
aws --endpoint-url http://<host>:9000 s3 ls s3://mymailbox/
aws --endpoint-url http://<host>:9000 s3 cp s3://mymailbox/attachments/1/file.pdf ./out.pdf
```

Verified against a real `aws-cli` (not a hand-rolled test signer): upload,
list, download (byte-identical), `s3api head-object`, and a wrong-secret
request correctly rejected with AWS's own `SignatureDoesNotMatch` error.

### Phase 2 scope limits (disclosed, not silently skipped)

- **ETag is the object's sha256 hex**, not AWS's MD5 (or the multipart
  composite format) — machin has no MD5 builtin. Most clients treat ETag as
  an opaque change-token; a strict byte-for-byte MD5 comparison would fail.
- **HEAD is not spec-correct.** `machweb` cannot send a non-zero
  Content-Length with a genuinely empty body (see the Phase 1 HEAD note
  above — same root cause), so Phase 2's HEAD sends the same body a GET
  would. Most client libraries tolerate this (they trust Content-Length and
  don't read further); a strict one might not. `aws s3api head-object`
  works because botocore only looks at headers.
- **Header-based SigV4 only** — no presigned URLs (`mc share` / `aws s3
  presign` links won't verify) and no `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`
  (chunked signing, used by some SDKs for large uploads by default).
- **No X-Amz-Date freshness check** — a captured, replayed request would
  still verify. Acceptable given this sits behind Tailscale, not the public
  internet; would need fixing before broader exposure.
- **Bucket create/delete is CLI-only**, same as Phase 1 — `aws s3 mb` / `mc
  mb` fail with a 501 pointing at `machin-esetres bucket create`.
- Signature comparison is a plain string `==`, not constant-time.

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

## Layout

```
machin-esetres/
├── src/
│   ├── store.src    # core: buckets, sha256-deduped objects, refcounted delete —
│   │                #   shared by the CLI and both HTTP front-ends, never die()s
│   ├── sigv4.src     # AWS SigV4 request verification (Phase 2)
│   ├── s3.src         # S3-compatible facade: path-style routing, XML, SigV4 auth
│   ├── server.src    # Phase 1 custom REST API (machweb wiring)
│   ├── main.src       # CLI dispatch (bucket/put/get/rm/ls/serve), agent-first
│   │                   #   contract (emit/die, exit codes)
│   └── test.src       # unit tests (98 assertions, no live process — Request/
│                       #   Response are plain structs, built directly)
├── build.sh          # machin encode (framework/flags + framework/machweb
│                       #   resolve from the compiler — nothing vendored) + build
├── test.sh           # `machin test` over src/test.src — unit coverage
├── smoke.sh          # CLI + Phase 1 HTTP + Phase 2 (real aws-cli) regression test
├── README.md
└── AGENTS.md         # architecture, decisions, open questions, verified claims
```
