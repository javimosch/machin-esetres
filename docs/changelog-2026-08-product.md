        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-blue-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">🪣</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">A real object store, from scratch</h3>
              <p class="text-white/40 leading-relaxed">Buckets, keys, upload/download/delete/list — a self-hosted alternative to reaching for MinIO or S3, built as one native binary with no runtime dependencies. Objects are content-addressed by SHA-256, so two uploads with identical bytes share one blob on disk automatically, and deleting one still-referenced copy never touches the data.</p>
            </div>
          </div>
        </div>

        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-emerald-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">🤖</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">Built for agents and scripts first</h3>
              <p class="text-white/40 leading-relaxed">Every command answers in one JSON envelope with semantic exit codes and a self-describing <code>help-json</code> — the same contract this ecosystem's other agent-first tools use, so nothing new to learn. A bearer token per bucket is all the setup a script needs.</p>
            </div>
          </div>
        </div>

        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-purple-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">☁️</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">Speaks real S3 too</h3>
              <p class="text-white/40 leading-relaxed">A second front-end verifies genuine AWS Signature V4 requests, so existing tools — <code>aws s3 cp</code>, <code>aws s3 ls</code>, any S3 SDK — can point straight at it with an access key and secret, no code changes. Verified end to end against a real <code>aws-cli</code>, not a hand-rolled test client.</p>
            </div>
          </div>
        </div>

        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-amber-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">🚀</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">Deployed and reachable</h3>
              <p class="text-white/40 leading-relaxed">Running as a systemd service on its own host, gated with a real health check and a full round-trip before going live — the same release discipline as the rest of this ecosystem's self-hosted tools.</p>
            </div>
          </div>
        </div>
