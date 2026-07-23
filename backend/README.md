# SceneFind Backend (Cloudflare Workers)

Production proxy that holds the Groq/Gemini keys server-side and implements the
`/v1` contract in [`../docs/PRODUCTION_BACKEND.md`](../docs/PRODUCTION_BACKEND.md).
The iOS app calls this instead of the providers directly, so no provider secret
ever ships in the app binary.

## Status

This is a **working skeleton**, not the finished backend. What's implemented vs.
stubbed:

| Area | State |
| --- | --- |
| Routing for all 5 `/v1` endpoints | ✅ implemented |
| Per-analysis Durable Object + SSE progress stream | ✅ implemented |
| Server-side Gemini identification + Groq verification | ✅ real calls (needs frames/transcript wired in) |
| App Attest / DeviceCheck auth | ⛔ stub, **fails closed** (see `src/auth.ts`) |
| Entitlement / StoreKit verification | ⛔ KV stub (`src/entitlement.ts`) |
| Media retrieval, artwork (TMDB), provider resolution | ⛔ TODOs in `src/session.ts` |

Search the source for `TODO` for the remaining work.

## Endpoints

- `POST /v1/analysis` → `{ id, requestID }`
- `GET /v1/analysis/{id}/events` → `text/event-stream` of `AnalysisProgressEvent`
- `DELETE /v1/analysis/{id}` → cancel + drop evidence
- `GET /v1/entitlement` → `EntitlementState`
- `POST /v1/storekit/transaction` → verify + return `EntitlementState`

The SSE stream emits one `data:` line per `AnalysisProgressEvent`; the final
`completed` event carries the full `ClipAnalysisResult` as JSON in its `detail`.

## Local development

```bash
cd backend
npm install
cp .dev.vars.example .dev.vars   # then fill in keys (see below)
npm run typecheck
npm run dev                      # wrangler dev
```

`.dev.vars` (gitignored) for local runs:

```
GROQ_API_KEY=gsk_...
GEMINI_API_KEY=AQ...
ALLOW_INSECURE_DEV_AUTH=1
```

`ALLOW_INSECURE_DEV_AUTH=1` bypasses App Attest **locally only** — never set it
in a deployed environment.

## Deploy

```bash
npx wrangler kv:namespace create RATE_LIMIT   # put the id in wrangler.toml
npx wrangler secret put GROQ_API_KEY
npx wrangler secret put GEMINI_API_KEY
npm run deploy
```

## Wiring the app to it

The app currently calls Gemini/Groq directly in `Shared/Services/`. To switch:

1. Add a `SceneFindBackendClient` that POSTs to `/v1/analysis` and consumes the
   SSE stream into `AnalysisProgressEvent` / `ClipAnalysisResult`.
2. Send the App Attest headers (`X-SceneFind-Install`, `X-SceneFind-Assertion`,
   `X-SceneFind-Token`).
3. Gate the direct provider clients behind `#if DEBUG` so prod always uses the
   proxy.
