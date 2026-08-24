# SceneFind Production Backend Contract

The direct Gemini and Groq clients are Debug prototype adapters. An App Store build must call a SceneFind-owned HTTPS proxy and must never ship provider secrets.

## Request Flow

1. The app creates an anonymous installation identity in Keychain and requests an App Attest key.
2. The share request uploads only the user-selected URL or media plus a short-lived signed request token.
3. The backend verifies App Attest or DeviceCheck, rate limits the installation and account, and checks StoreKit server entitlement state.
4. The backend reserves one free success without consuming it. The reservation is committed only when a useful show-level or better result is returned.
5. The backend runs retrieval, Gemini multimodal analysis, Groq episode verification, artwork lookup, and provider resolution.
6. Logs store redacted hosts, stage timing, provider status codes, and confidence bands. Clip URLs, transcripts, and frames expire on a short retention schedule.

## API Shape

- `POST /v1/analysis`: create an analysis and return an opaque ID.
- `GET /v1/analysis/{id}/events`: server-sent events using `AnalysisProgressEvent` fields.
- `DELETE /v1/analysis/{id}`: cancel work and delete temporary evidence.
- `GET /v1/entitlement`: authoritative allowance and subscription state.
- `POST /v1/storekit/transaction`: submit signed StoreKit transaction data for server verification.

All responses use strict schemas. Provider errors are mapped to stable public error codes; raw provider bodies and secrets never reach the client.

## Abuse And Reliability

- App Attest assertion per analysis, with DeviceCheck fallback.
- Per-installation, per-account, per-IP, and global model-budget limits.
- Idempotency keys prevent duplicate charges and duplicate allowance consumption.
- Circuit breakers and bounded provider failover; no retry after schema validation failure.
- Metrics: show-level success, verified-episode success, false-positive reports, p50/p95 stage latency, provider downgrade reason, and cost per successful result.
- Premium is unlimited for normal use, with documented fair-use limits for automated or abusive traffic.

The current `DailyUsageLimiter` is deliberately local prototype enforcement. It is not a security boundary and must be replaced by the authoritative backend allowance before release.
