# SceneFind Backend

Cloudflare Worker that owns provider credentials, verifies Apple transactions
and App Attest assertions, enforces allowances atomically, and streams analysis
progress to the iOS app.

## Entitlement policy

| Product | Product ID | Price | Successful identifications |
| --- | --- | ---: | ---: |
| Free | none | $0 | 2 total per installation |
| Starter | `com.kavigandham.scenefind.starter.monthly` | $0.99/month | 10 per Apple billing period |
| Pro | `com.kavigandham.scenefind.pro.monthly` | $9.99/month | 50 per Apple billing period |
| Lifetime | `com.kavigandham.scenefind.lifetime` | $19.99 once | 10 per UTC calendar month |

The `EntitlementLedger` Durable Object serializes reserve/commit/release
operations. A reservation is committed only when an identification succeeds;
failures and cancellation release it. Idempotency keys prevent a repeated
client request from consuming allowance twice.

## Security boundaries

- Provider keys exist only as Worker secrets.
- Every production client request requires a fresh App Attest challenge and an
  assertion over installation ID, key ID, method, path, body hash, and time.
- App Store transaction and notification JWS values are verified against the
  bundled Apple G2/G3 roots with Apple's official server library.
- The first transaction claim must carry the attested installation UUID as its
  StoreKit `appAccountToken`. A verified restore on another device joins the
  original transaction's existing ledger, so all devices share one allowance
  instead of creating additional quota.
- Only Apple Sandbox and Production environments, the SceneFind bundle ID, and
  the three known product IDs are accepted.
- Rate limits are applied by installation and IP. Exact quota accounting lives
  in a Durable Object; Cloudflare KV is not used as the quota authority.
- Public errors and logs exclude raw provider responses, shared URLs,
  transcripts, media, assertions, and transaction payloads.

Public YouTube URLs are sent to Gemini as video input when signature-protected
platform playback prevents bounded direct-media retrieval. Other remote URLs
are never forwarded as provider `fileData`; they use retrieved, size-limited
media or metadata/thumbnail evidence instead.

TikTok and YouTube timed captions are preserved as individual cues. Scene
timestamps are emitted only when QuoDB returns the identified title and either
multiple dialogue anchors agree within four seconds or one high-similarity
anchor ends within eight seconds of the shared clip. Multiple-anchor matches
must also cover the clip ending within 20 seconds. Missing, early-only, or
inconsistent anchors produce no timestamp. With three or more anchors, the last
one is held out and must agree with the earlier alignment within four seconds.
The end time uses the median offset of the latest three anchors plus source
duration; it is not a model estimate. TikTok's integer-only duration receives a
0.5-second midpoint correction to remove its systematic early bias. If platform
captions are absent or do not align, the Worker can request timed segment
transcription from Groq and applies the same fail-closed timeline rules.

For television results, the dialogue-index episode title is independently
mapped to an exact season and episode through TVMaze. When result snippets are
insufficient, an untrusted caption/model coordinate may select a real guide
entry to investigate, but the episode passes only when the clip's dialogue is
found on that episode's transcript page. Deterministic evidence returns before
the optional Groq tie-breaker, so a Groq outage cannot invalidate an already
proven episode. Ambiguous multi-part episode names remain unresolved.

The App Attest verifier is the third-party `node-app-attest` package. Its
behavior must be proven on a physical production-entitled device against the
deployed Worker before release; a simulator cannot satisfy that gate.

## Endpoints

- `POST /v1/attest/challenge`
- `POST /v1/attest/register`
- `POST /v1/analysis`
- `GET /v1/analysis/{id}/events`
- `DELETE /v1/analysis/{id}`
- `GET /v1/entitlement`
- `POST /v1/storekit/transaction`
- `POST /v1/app-store/notifications`

## Local verification

Node.js 22 or newer is required by the pinned production Wrangler toolchain.

```sh
npm ci
npm run typecheck
npm test
npm run regression:tiktok:episodes
npx wrangler deploy --dry-run --outdir /tmp/scenefind-worker
```

For local-only simulator work, copy `.dev.vars.example` to `.dev.vars`.
`ALLOW_INSECURE_DEV_AUTH=1` is honored only when the request hostname is
`localhost` or `127.0.0.1`.

## Deployment prerequisites

1. Replace both `REPLACE_WITH_KV_NAMESPACE_ID` values in `wrangler.toml`.
2. Set Worker secrets `GROQ_API_KEY`, `GEMINI_API_KEY`,
   `APPLE_TEAM_ID`, and optionally `SEARCH_API_KEY`.
3. Set `APPLE_APP_ID` to the numeric App Store Connect app ID.
4. Create all three products in App Store Connect with the IDs and prices
   above. Starter and Pro belong to one subscription group; Lifetime is a
   non-consumable.
5. Configure App Store Server Notifications V2 to post to
   `/v1/app-store/notifications`.
6. Configure the iOS build with the deployed HTTPS backend URL plus live
   privacy, terms, and support URLs.

Do not deploy while any placeholder namespace ID remains.
