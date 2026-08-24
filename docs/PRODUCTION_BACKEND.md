# SceneFind Production Backend Contract

Release and TestFlight builds call a SceneFind-owned HTTPS backend and contain
no Gemini, Groq, or search-provider credentials. Direct provider adapters are
compiled for Debug development only.

## Request flow

1. The app keeps an anonymous installation UUID and App Attest key ID in
   Keychain.
2. It obtains a fresh five-minute backend challenge and registers the Apple
   attestation when needed.
3. Each protected request carries an assertion over the method, path, request
   body SHA-256, installation ID, key ID, challenge, and timestamp.
4. The backend verifies the assertion, applies install/IP limits, and reserves
   an allowance in the installation's serialized entitlement ledger.
5. Retrieval collects public platform metadata, transcript/caption evidence,
   and bounded direct media or thumbnails without bypassing authentication,
   DRM, or platform controls. Public YouTube URLs can be passed as provider
   video input when a signature-protected media URL cannot be retrieved.
6. Gemini returns schema-constrained identification evidence. Exact transcript
   anchors and canonical TVMaze episode metadata are resolved deterministically;
   candidate episode transcript pages are fetched when indexed snippets omit
   the dialogue. Groq is only a bounded tie-breaker and timed-transcription
   fallback, never a dependency for already-proven episode evidence. Timed
   dialogue is aligned through QuoDB. Clip endings use the latest
   dialogue anchors, reject held-out final-anchor disagreement over four
   seconds, and correct TikTok's integer-duration truncation. Uncertain episode
   or ending fields are removed, and a low-confidence identification returns no
   match.
7. A useful result commits exactly one reservation. Failure and cancellation
   release it. SSE progress reports completed work, not timers.

## Authoritative allowance

| Plan | Allowance window |
| --- | --- |
| Free | 2 successful identifications for the installation's lifetime |
| Starter | 10 per verified Apple subscription billing period |
| Pro | 50 per verified Apple subscription billing period |
| Lifetime | 10 per UTC calendar month |

The backend is authoritative. The app's last-known state is display-only while
offline and cannot authorize an analysis. Grace period remains usable until its
verified end; billing retry, expiry, revocation, and refund fail closed.

## StoreKit

The app submits StoreKit's signed transaction JWS and finishes the transaction
only after server acceptance. The Worker verifies the JWS certificate chain,
bundle ID, environment, numeric production app ID, and known product ID using
Apple's App Store Server Library. Notifications V2 use the same verification
path and update the original transaction owner's ledger for renewals, grace,
billing retry, expiration, revocation, and refund.

## Data and logging

User-selected URLs, text, images, and videos are used only for the requested
analysis. They are not written to logs or entitlement storage. Logs contain
opaque request/install prefixes, stage timing, status, and error category.
Durable analysis state is cleared after terminal handling; an operational
retention/deletion policy still must be configured and verified in the deployed
Cloudflare account.

## Deployment gate

The checked-in Worker bundles successfully, but it is not a deployed production
service while `wrangler.toml` contains placeholder KV namespace IDs or the
required Apple/provider secrets are absent. Physical-device App Attest,
Sandbox/Production StoreKit, Notifications V2, load, abuse, retention, and
observability tests are release-blocking external gates.
