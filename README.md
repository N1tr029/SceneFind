# SceneFind

SceneFind is an iPhone app for identifying the original movie or TV moment
behind a user-selected social clip, imported video, image, text, or URL. It
returns an evidence-scored title and only includes season, episode, timestamp,
or watch destinations when those fields can be verified.

## Repository

- SwiftUI iOS app and share extension
- App Group request handoff and `scenefind://analyze` deep link
- StoreKit 2 purchase, restore, updates, and server-signed entitlement sync
- Keychain installation identity and App Attest client
- Cloudflare Worker with atomic allowance enforcement, App Store JWS
  verification, Notifications V2, retrieval, model orchestration, SSE progress,
  rate limiting, and verified provider links
- Deterministic Swift and TypeScript test suites

Production and TestFlight builds never call model providers directly and never
contain provider keys. Debug builds retain local adapters for development.

## Products

| Plan | Price | Successful identifications |
| --- | ---: | ---: |
| Free | $0 | 4 total |
| Starter | $4.99/month | 10 per billing period |
| Pro | $19.99/month | 50 per billing period |
| Starter Yearly | $49.99/year | 10 per UTC calendar month |
| Pro Yearly | $199.99/year | 50 per UTC calendar month |

Prices were re-cut on 2026-09-16 to hold at least 2x the roughly 9 cents an
identification costs at the providers. **Lifetime is retired** (removed from
sale 2026-09-16): one-time revenue against a recurring cost went underwater,
and it undercut both subscriptions. Existing owners keep it and the backend
still honours plan `lifetime` at 10 a month.

A free trial of four is a *server-side* number (`FREE_TRIAL_ALLOWANCE` in
`backend/src/entitlement.ts`), so it only takes effect once the Worker is
deployed -- a shipped build alone still hands new installs the old two. The
size is stamped onto each ledger when it is first touched, so an install that
had already spent the old trial of two does not get two more.

The backend—not local device state—is the allowance authority. Failures do not
consume allowance, duplicate requests are idempotent, and production analysis
fails closed while entitlement cannot be checked.

## Generate and verify the iOS app

```sh
xcodegen generate
xcodebuild -project SceneFind.xcodeproj \
  -scheme SceneFind \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

Open `SceneFind.xcodeproj` to run the app or the share extension. The
`SceneFindLiveRegression` scheme is opt-in and can spend provider quota; its
old six-clip result is historical, not the production accuracy gate.

## Verify the backend

```sh
cd backend
npm ci
npm run typecheck
npm test
npx wrangler deploy --dry-run --outdir /tmp/scenefind-worker
```

Deployment variables, secrets, Apple configuration, and endpoint details are in
`backend/README.md` and `docs/PRODUCTION_BACKEND.md`.

## Privacy and security

SceneFind processes only content the user explicitly shares or imports. It does
not bypass login, DRM, or platform controls. User URLs, media, transcripts,
transaction JWS values, and App Attest assertions are excluded from logs.
Non-Debug builds scan their output for provider keys and reject a contaminated
product.

Watch URLs are not invented by the model. The backend searches for candidate
provider pages, follows bounded redirects, checks page metadata for the same
title and requested episode, rejects foreign storefronts for the selected
region, and omits any destination that cannot be verified.

## Deploy the backend

Production and TestFlight builds carry no provider keys, so they are inert
until the Worker is live. After `npx wrangler login` and setting the Worker
secrets, one command provisions, verifies, deploys, and wires the URL into the
app:

```sh
./backend/deploy.sh
```

Until it has run, `SCENEFIND_BACKEND_URL` is empty and every non-Debug build
fails at the configuration gate. That is deliberate: a guessed URL would ship a
build that silently fails every identification.

## Public pages

`site/` holds the privacy policy, terms of use, and support pages that the App
Store listing and the app's `SCENEFIND_*_URL` settings point at. Pushing to
`main` publishes them to <https://n1tr029.github.io/SceneFind/> via
`.github/workflows/pages.yml`; nothing else in the repository is served.

## Release status

SceneFind is live on the App Store. **Version 1.0.2 has been the public
build since 2026-09-16**; 1.0.3 archived green on both Xcode Cloud workflows
and was never submitted, and 1.0.4 adds the billing and run-state fixes on
top of it. So the shipped app is two releases behind this repository, and the
fixes customers most need -- the re-import that started a second paid
analysis, the retry race that stranded a charged run on a spinner, and the
per-launch KV write that could lock paying subscribers out until UTC midnight
-- are not in anyone's hands yet.

The ordered runbook, and the gates that genuinely remain, are in
`docs/APP_STORE_SUBMISSION_CHECKLIST.md`. `docs/APP_STORE_READINESS_AUDIT.md`
is the older evidence log and predates the launch; read it as history, not as
current state. A green local build is not a release: the Worker deploy, the
App Store Connect version, physical App Attest, signed StoreKit scenarios and
the Instagram ground-truth regression are all still external gates.
