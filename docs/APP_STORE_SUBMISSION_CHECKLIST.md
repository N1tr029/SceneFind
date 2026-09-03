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

Mostly done as of 2026-08-29. App Apple ID is **6792423118** — that numeric ID,
not the bundle ID, is the `APPLE_APP_ID` Worker secret.

- [x] All three products exist with the exact IDs entitlement lookup requires:
      | Product | ID | Apple ID | Price |
      | --- | --- | --- | ---: |
      | Starter | `com.kavigandham.scenefind.starter.monthly` | 6807253941 | $0.99/mo |
      | Pro | `com.kavigandham.scenefind.pro.monthly` | 6807254844 | $9.99/mo |
      | Lifetime | `com.kavigandham.scenefind.lifetime` | 6807253318 | $19.99 once |
      Subscription group "SceneFind Plans" is 22350290.
- [x] Localized display names and descriptions on all three.
- [x] Subscription levels ordered by service: Pro is level 1, Starter level 2, so
      Starter → Pro is an immediate upgrade rather than a deferred downgrade.
      The level UI is a react-beautiful-dnd widget that ignores synthetic drag
      and keyboard entirely; this was set through the ASC API instead.
- [x] Review notes on all three products explaining that the charge is for
      identification work, that allowance is server-side and consumed only on
      success, and where the paywall lives.
- [x] Review screenshot attached to all three products (2026-09-02). Pro and
      the group read "Ready for Review". The `state` field the iris API returns
      stays `MISSING_METADATA` even after the UI flips, so judge readiness from
      the page status, not the API.
- [x] **App price and availability.** This was the real blocker behind
      `MISSING_METADATA`, not the screenshots: the app had no price tier and no
      territories, and StoreKit refuses to serve products for an app with
      neither. Now Free across all 175 regions. The paywall loads all three
      products with live prices on device and in the simulator.
- [x] Draft review submission assembled with all four items — Pro, Starter,
      the SceneFind Plans group, and Lifetime. Build 69 is attached to version
      1.0. The only thing left is adding the app version to the draft and
      pressing Submit, which is deliberately left to Hassan: the version-add
      dialog is worded "submit this build for review", and build 69 is no
      longer the newest — swap to the latest build first and that warning
      disappears.
- [x] App Information: category Entertainment + Photo & Video, subtitle,
      Content Rights answered, age rating questionnaire completed → **4+**.
- [x] App Privacy published — Device ID, Other User Content, Purchase History
      and Performance Data, all App Functionality, none linked to identity,
      none used for tracking. Matches `PrivacyInfo.xcprivacy`; keep the two in
      step or review will flag the contradiction.
- [x] Version 1.0 metadata: description with the full auto-renewable
      disclosure, keywords, promotional text, support and marketing URLs,
      copyright, and App Review notes covering guidelines 5.2.2 and 5.2.3.
- [x] Release set to **manual**, so an approved v1 does not go live before the
      backend has taken real traffic.
- [x] "Sign-in required" unchecked — the app has no login, and leaving it
      ticked makes review wait for credentials that do not exist.
- [x] App Review contact information.
- [ ] Set `[JURISDICTION]` in `site/terms.html`. The legal entity is filled in
      as "Kavi Gandham" to match the Apple seller name and the copyright line;
      governing law is a legal choice and is still a visible placeholder on the
      live page.
- [x] Digital Services Act trader status — Active for 27 countries. Paid Apps
      Agreement, bank account and W-9 were already active too.
- [ ] Resolve the standing "cannot identify your GitHub account — relink"
      warning on the Builds page.
- [x] App Store Server Notifications V2 point at the Worker for both production
      and sandbox.

## Group 3 — Signing and the first real build

Xcode Cloud builds 41, 43, 45 and 47 all failed with "Exporting for App Store
Distribution failed" and the TestFlight post-action never ran, which is why the
newest TestFlight build sat at 37 from 2026-07-25. The cause was the App Attest
entitlement `com.apple.developer.devicecheck.appattest-environment`, added in
2ff2212 on 2026-08-24 — the first failing build is the first one after it, with
four failures since and none before.

- [x] Enable the **App Attest** capability on App ID `com.kavigandham.scenefind`
      in the Developer portal for team T4VT6R837D (reported done 2026-09-01).
      Note this cannot be seen or done from the Shafiq and Company LLC account:
      developer.apple.com lists only 8Q5ZM85YCZ and ignores `?teamId=`.
- [ ] Confirm the next build's Archive action succeeds and the TestFlight
      post-action actually runs. A green Archive is not enough — check the
      post-action, because it can fail while the build reads as successful.
- [ ] Relink GitHub in Xcode Cloud ("Authorize" on the Builds banner). While it
      is unlinked, **Start Build and Rebuild are disabled**, so the only way to
      trigger a build is to push a commit.


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
- [x] Submitted 2026-09-02: version 1.0 with build 71 plus Pro, Starter, the
      subscription group and Lifetime as a single review submission. Waiting
      for Review; Apple quotes up to 48 hours. Manual release is set, so
      approval does not publish it.

---

## Standing traps

- Xcode Cloud builds only what is pushed to `origin/main`. Local-only changes
  never reach a build.
- A missing encryption declaration silently prevents distribution while the
  build itself still reports success.
- App Store Connect's web UI renders an empty workflow list; workflows are
  editable only from Xcode.
