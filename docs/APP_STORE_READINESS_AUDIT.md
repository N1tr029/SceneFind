# SceneFind App Store Readiness Audit

Audit date: 2026-08-29 (previous: 2026-08-19). “Implemented” means present in the repository and
covered by the stated local evidence. It does not mean an external App Store,
Cloudflare, physical-device, or social-platform gate was completed.

## Implemented and locally verified

- Exact products: Starter $0.99/month for 10, Pro $9.99/month for 50, and
  Lifetime $19.99 once for 10 per UTC calendar month.
- Free allowance is 2 successful identifications total. No daily reset or
  TestFlight/premium bypass remains.
- StoreKit purchases, restores, current entitlements, transaction updates,
  expiration, grace, billing retry, revocation, and refund are submitted to the
  backend. Transactions finish only after server acceptance.
- Backend quota reserve/commit/release is serialized in a Durable Object and
  idempotent. Concurrent allowance tests pass.
- Production/TestFlight identification uses the backend only and fails closed
  offline. Provider keys are Debug-only and a non-Debug product scan rejects
  secret-shaped content.
- App Attest challenge, registration, assertion verification, replay
  prevention, request binding, and monotonic counters are implemented.
- Provider work has bounded timeouts/retries, schema validation, evidence
  thresholds, honest no-match behavior, and no raw provider errors.
- Episode/storefront URLs are emitted only after destination-page evidence.
- Privacy manifest, Keychain identity, App Group, share extension, custom deep
  link, cancellation, loading/error states, and purchase disclosure are present.
- Simulator evidence (2026-08-29): 63 Swift tests passed, 0 failed, 2
  live-network tests skipped.
- TestFlight configuration builds for generic iOS with signing disabled at
  version 1.0 build 11. The app and share extension are present, no prototype
  plist or provider-key pattern is found, and `ITSAppUsesNonExemptEncryption`
  is set so distribution is not held at export compliance. This is not an
  uploadable archive. A signed attempt failed because Xcode has no account for
  team `T4VT6R837D` and no provisioning profiles for either bundle ID.
- The four release URLs are wired in `project.yml` for Release and TestFlight.
  Privacy, terms, and support resolve to the GitHub Pages site published from
  `site/` by `.github/workflows/pages.yml`. `SCENEFIND_BACKEND_URL` is
  deliberately empty until the Worker is deployed. Both directions of the gate
  were exercised on 2026-08-29: an empty backend URL fails the build with
  `error: SCENEFIND_BACKEND_URL must be configured as an HTTPS URL for
  TestFlight`, and with all four set the build succeeds and the values appear
  in the built `Info.plist`.
- Final app icon is in place: a film cell inside autofocus brackets, replacing
  the generic magnifying glass. All eight catalog sizes plus the 1024 marketing
  asset are RGB with no alpha channel, and the compiled 120px bundle icon was
  confirmed byte-identical to its source.
- Worker evidence (2026-08-29): typecheck passed, 42 tests across 8 files
  passed, production bundle dry-run succeeded with Wrangler 4.124.0 on
  Node 24 (1,927.83 KiB upload / 319.52 KiB gzip), and the complete dependency
  audit reported 0 vulnerabilities.

## Release blockers

- **Deploy the Worker.** This is the gating blocker: nothing downstream can be
  validated without it, and until it is done every non-Debug build fails closed
  at the URL gate by design. Run `npx wrangler login`, set the secrets
  (`GEMINI_API_KEY`, `GROQ_API_KEY`, `APPLE_TEAM_ID`, `APPLE_APP_ID`, and
  optionally `SEARCH_API_KEY`) with `wrangler secret put`, then run
  `backend/deploy.sh`. The script provisions both KV namespaces and writes their
  real IDs into `wrangler.toml`, verifies the secrets, runs typecheck and tests,
  deploys, smoke-tests `/healthz`, writes the deployed URL into `project.yml` as
  `SCENEFIND_BACKEND_URL`, and regenerates the project. Configure App Store
  Server Notifications V2 to point at the deployed Worker afterwards.
  The privacy, terms, and support URLs are configured and no longer block.
- Create/approve all three exact products and subscription metadata in App
  Store Connect. StoreKit configuration is local metadata, not proof of App
  Store Connect state.
- Validate production App Attest through the deployed backend on a physical
  iPhone. Both detected iPhones were unavailable during this audit.
- Validate sandbox purchase, renewal, upgrade/downgrade, grace, billing retry,
  refund/revocation, reinstall, restore, and Lifetime calendar rollover with
  real signed Apple transactions.
- Run and document the requested 50 distinct signed-in Instagram clip corpus
  with ground-truth show/season/episode labels. Do not report episode accuracy
  until those labels have been independently verified.
- Add and measure explicit decoded video-frame sampling/OCR if the deployed
  Gemini video path does not satisfy the accuracy/latency gates. The current
  backend gives Gemini bounded inline video or a public YouTube URL plus the
  thumbnail and asks it to inspect frames/OCR, but does not independently
  decode or count sampled frames. YouTube URL input is a provider preview
  feature and must be monitored for API/pricing changes.
- Integrate or validate authenticated region availability. Verified public
  provider pages are not equivalent to proof that a title is playable for a
  specific subscriber in a specific region.
- Add production crash reporting/alerts, validate retention/deletion controls,
  execute abuse/load tests, and review operational dashboards.
- Track the deprecated `jsrsasign@11.1.5` transitive dependency currently used
  by Apple's App Store Server Library. It has no reported audit vulnerability
  in this lockfile, but remains a maintenance/supply-chain risk.
- Supply App Store screenshots, privacy labels, age rating, review notes,
  localizations, and a support contact email in App Store Connect. The icon,
  privacy page, terms page, and support page are done; export compliance is
  answered in `Info.plist`. Before submission, replace the `[LEGAL ENTITY]` and
  `[JURISDICTION]` placeholders in `site/terms.html`.
- Produce and validate a signed archive only after the preceding configuration
  exists; then upload build 11 to TestFlight and run the physical share,
  playback, background/foreground, poor-network, and offline matrix.

## Accuracy and latency gate

The previous six-clip live snapshot is retained in `REGRESSION_RESULTS.md`
only as historical prototype evidence. It is not the requested 50-Instagram
regression and contains no independently verified episode ground truth.
Therefore this audit makes no episode-accuracy or production-latency claim.

## Release verdict

**Not ready for App Store submission.** The repository is materially closer and
its local gates pass, but the deployment, signed Apple, physical-device,
50-Instagram, observability, metadata, and signed archive gates above remain
open. This verdict must not be changed until evidence is attached for every
release blocker.
