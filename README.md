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
| Free | $0 | 2 total |
| Starter | $0.99/month | 10 per billing period |
| Pro | $9.99/month | 50 per billing period |
| Lifetime | $19.99 once | 10 per UTC calendar month |

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

The current evidence and every open external gate are recorded in
`docs/APP_STORE_READINESS_AUDIT.md`, and the order to clear them in is in
`docs/APP_STORE_SUBMISSION_CHECKLIST.md`. A successful local build is not
sufficient for release: deployed backend, App Store Connect products, physical
App Attest, signed StoreKit scenarios, the 50-Instagram ground-truth
regression, observability, metadata, signed archive, and TestFlight validation
are required.
