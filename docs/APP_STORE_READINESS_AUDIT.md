# SceneFind Readiness Audit

## P0

- **Provider secrets in client builds:** Debug may load ignored `PrototypeSecrets.plist`; non-Debug builds remove it and scan the product for known key shapes. Production still requires the backend in `PRODUCTION_BACKEND.md` before submission.
- **False progress:** the previous screen advanced on fixed 1/2/4/7/10 second timers. It now renders only pipeline events stamped when work completes.
- **Unbounded long tail:** malformed model output retried the full video request, model fallback could issue six calls, Groq waited 60 seconds, and failed Groq verification launched another Gemini call. The expensive request now runs once, fallback is bounded to one alternate model, Groq has a 6 second timeout, episode-guide lookup has a 4 second timeout, and uncertain episodes degrade to show-level results.
- **Wrong streaming content:** routes are now classified as exact episode, show, or search. Exact pages require title and episode evidence, Hulu UUIDs require season/episode corroboration, and supplied Hulu series URLs are preserved.

## P1

- Canonical TikTok destinations survive redirects; page video/thumbnail evidence survives oEmbed failure.
- Small media is attached inline, avoiding download-upload-processing round trips. Larger files retain the resumable upload path.
- URLSession calls are cancellation-aware and have explicit deadlines.
- Artwork is fetched only for the top result and no longer blocks every alternative.
- StoreKit 2 models monthly/yearly products, purchase, restore, transaction updates, expiration, revocation, grace, billing retry, and offline last-known state.
- Free users receive two successful results per local day. Failures and premium results do not consume the local allowance.
- Privacy manifests cover user content and app-group/defaults API use.
- Destination validation is cached by provider, title, season, and episode with acceptance/downgrade diagnostics.

## P2 / External

- Replace `com.example` identifiers, App Group, product IDs, and empty Development Team using the final Apple account.
- Deploy the backend proxy, StoreKit server notifications, App Attest, privacy policy, terms, account/data deletion, retention controls, and support URLs.
- Add authenticated availability data. SceneFind currently records a user’s service access but does not connect to streaming accounts.
- Complete App Store Connect products, prices, screenshots, privacy labels, review notes, and subscription localization.
- Add UI automation for share-sheet handoff and purchase states once signing and the final app group are available.

## Timing

| Stage | Before | Current bound |
|---|---:|---:|
| Fake steps 1-5 | about 10s (user-observed) | removed |
| Main multimodal model | up to 6 x 120s | 1 preferred + 1 busy-only fallback, 35s each |
| Episode verification | 60s plus Gemini fallback | 6s Groq + 4s guide, no second multimodal request |
| File processing poll | 60s | 30s; files up to 12 MB inline |
| Overall user-observed total | often about 70s | target under 30s on normal public short clips |

The before values are the user-observed baseline and code-path maximums, not a controlled benchmark. Measured live-corpus outcomes and their limitations are in `REGRESSION_RESULTS.md`; no episode-accuracy percentage is inferred without ground-truth labels.
