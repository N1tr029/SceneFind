# SceneFind App Store Submission Runbook

`APP_STORE_READINESS_AUDIT.md` records *what* is still open and the evidence
behind each claim. This file records the *order* to clear it in, because most
of the remaining gates cannot be started until the Worker is live.

Steps are grouped so that everything inside a group can be done in parallel,
but each group depends on the one before it.

---

## Group 1 — Deploy the backend

Nothing else can be validated first: the app is keyless, so a build with no
backend cannot identify anything, and the build gate refuses to produce one.

- [ ] `npx wrangler login`
- [ ] Set the Worker secrets. `wrangler` prompts for each value; nothing is
      echoed or written to the repo.
      ```
      cd backend
      npx wrangler secret put GEMINI_API_KEY
      npx wrangler secret put GROQ_API_KEY
      npx wrangler secret put APPLE_TEAM_ID     # T4VT6R837D
      npx wrangler secret put APPLE_APP_ID      # numeric Apple ID from App Store Connect
      npx wrangler secret put SEARCH_API_KEY    # optional; watch-link search is disabled without it
      ```
- [ ] `./backend/deploy.sh` — provisions both KV namespaces, verifies the
      secrets, runs typecheck and tests, deploys, smoke-tests `/healthz`, writes
      the deployed URL into `project.yml`, and regenerates the project.
- [ ] Commit and push the resulting `project.yml` and `backend/wrangler.toml`.
- [ ] Point App Store Server Notifications V2 at
      `<worker-url>/v1/app-store/notifications`.

## Group 2 — App Store Connect setup

- [ ] Create the three products with these exact IDs, or entitlement lookups
      will not match:
      | Product | ID | Price |
      | --- | --- | ---: |
      | Starter | `com.kavigandham.scenefind.starter.monthly` | $0.99/mo |
      | Pro | `com.kavigandham.scenefind.pro.monthly` | $9.99/mo |
      | Lifetime | `com.kavigandham.scenefind.lifetime` | $19.99 once |
- [ ] Add subscription group metadata, localized display names, and review
      screenshots for each product.
- [ ] Fill in App Information: category, age rating, support URL
      (`https://n1tr029.github.io/SceneFind/support.html`), privacy policy URL
      (`https://n1tr029.github.io/SceneFind/privacy.html`), and a support
      contact email.
- [ ] Complete the App Privacy questionnaire. It must agree with
      `SceneFindApp/Resources/PrivacyInfo.xcprivacy`, which declares other user
      content, device ID, purchase history, and performance data — all as app
      functionality, none linked to identity, none used for tracking.
- [ ] Resolve the standing "cannot identify your GitHub account — relink"
      warning on the Builds page.
- [ ] Replace `[LEGAL ENTITY]` and `[JURISDICTION]` in `site/terms.html`, then
      push. Both render as highlighted placeholders until you do.

## Group 3 — Signing and the first real build

- [ ] Add an Apple Developer account for team `T4VT6R837D` in Xcode and create
      distribution provisioning profiles for `com.kavigandham.scenefind` and
      `com.kavigandham.scenefind.ShareExtension`. Automatic signing has never
      succeeded locally because no account is present.
- [ ] Confirm the Xcode Cloud workflow's TestFlight post-action targets the
      intended tester group. App Store Connect's web UI cannot edit workflows —
      use Xcode, Product → Xcode Cloud → Manage Workflows.
- [ ] Verify the delivered build reaches testers rather than stalling. Export
      compliance is already answered by `ITSAppUsesNonExemptEncryption` in
      `Info.plist`; if a build regresses to "not distributed", read the
      post-action error, not the build status.

## Group 4 — Validation that needs the deployed backend and a physical device

- [ ] App Attest end to end on a physical iPhone against the production Worker.
      The simulator cannot exercise this.
- [ ] Sandbox StoreKit matrix: purchase, renewal, upgrade, downgrade, grace
      period, billing retry, refund, revocation, reinstall, restore across two
      devices, and Lifetime rollover across a UTC month boundary.
- [ ] Physical share-sheet matrix: share from TikTok, Instagram, YouTube, and
      Photos; background/foreground during analysis; poor network; airplane
      mode. Confirm failures release allowance rather than consuming it.
- [ ] The 50-clip Instagram regression with independently verified
      show/season/episode ground truth. Do not publish an accuracy number
      before the labels are verified — the six-clip snapshot in
      `REGRESSION_RESULTS.md` is prototype history, not a gate.

## Group 5 — Operational readiness

- [ ] Crash reporting and alerting on the Worker's error rate and p95 latency.
- [ ] Exercise the data deletion path described in the privacy policy.
- [ ] Abuse and load testing against the rate limits.
- [ ] Track `jsrsasign@11.1.5`, a deprecated transitive dependency of Apple's
      App Store Server Library. No advisory applies to the current lockfile;
      it is a maintenance risk, not a live vulnerability.

## Group 6 — Listing and submit

- [ ] Screenshots for every required iPhone display size.
- [ ] Description, keywords, promotional text, and what's-new.
- [ ] Review notes: explain that SceneFind identifies content the user already
      has access to and never downloads, decrypts, or bypasses DRM. Reviewers
      reject scene-identification apps that look like piracy tools, so state
      this plainly and give a demo clip that reproduces a successful result.
- [ ] Demo account: not required — the app has no login.
- [ ] Submit for review.

---

## Standing traps

- Xcode Cloud builds only what is pushed to `origin/main`. Local-only changes
  never reach a build.
- A missing encryption declaration silently prevents distribution while the
  build itself still reports success.
- App Store Connect's web UI renders an empty workflow list; workflows are
  editable only from Xcode.
