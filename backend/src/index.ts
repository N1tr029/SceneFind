// SceneFind production proxy — Cloudflare Worker entry point.
//
// Implements the /v1 contract from docs/PRODUCTION_BACKEND.md. Provider keys
// live only in Worker secrets; the client authenticates with App Attest and
// never sees a provider key or a raw provider error.
//
//   POST   /v1/analysis                 create analysis -> { id }
//   GET    /v1/analysis/{id}/events     SSE progress stream
//   DELETE /v1/analysis/{id}            cancel + drop evidence
//   GET    /v1/entitlement              allowance + subscription state
//   POST   /v1/storekit/transaction     server-side StoreKit verification

import type { AnalysisRequest, Env, PublicError, PublicErrorCode } from "./types";
import { authenticate, AuthError } from "./auth";
import { getEntitlement, verifyStoreKitTransaction } from "./entitlement";

export { AnalysisSession } from "./session";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    try {
      return await route(req, env);
    } catch (err) {
      if (err instanceof AuthError) return json(err.body, err.status);
      console.error("unhandled", err);
      return errorResponse("internal", "Unexpected error.", 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function route(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname;

  if (path === "/v1/analysis" && req.method === "POST") {
    return createAnalysis(req, env);
  }

  const eventsMatch = path.match(/^\/v1\/analysis\/([^/]+)\/events$/);
  if (eventsMatch && req.method === "GET") {
    return proxyToSession(env, eventsMatch[1], "GET", "/events", req);
  }

  const analysisMatch = path.match(/^\/v1\/analysis\/([^/]+)$/);
  if (analysisMatch && req.method === "DELETE") {
    await authenticate(req, env);
    return proxyToSession(env, analysisMatch[1], "DELETE", "/cancel", req);
  }

  if (path === "/v1/entitlement" && req.method === "GET") {
    const id = await authenticate(req, env);
    return json(await getEntitlement(env, id.installationID));
  }

  if (path === "/v1/storekit/transaction" && req.method === "POST") {
    const id = await authenticate(req, env);
    return json(await verifyStoreKitTransaction(env, id.installationID, await req.json()));
  }

  if (path === "/healthz") return new Response("ok");

  return errorResponse("not_found", "No such route.", 404);
}

async function createAnalysis(req: Request, env: Env): Promise<Response> {
  const identity = await authenticate(req, env);

  // Entitlement gate: reserve one free success without consuming it yet.
  const entitlement = await getEntitlement(env, identity.installationID);
  if (!entitlement.isPremium && entitlement.freeRemaining <= 0) {
    return errorResponse("entitlement_exhausted", "No free analyses remaining.", 402);
  }

  let body: AnalysisRequest;
  try {
    body = (await req.json()) as AnalysisRequest;
  } catch {
    return errorResponse("invalid_request", "Body must be JSON.", 400);
  }
  if (!body.sourceURL) {
    return errorResponse("unsupported_source", "A sourceURL is required.", 400);
  }

  const analysisID = crypto.randomUUID();
  const requestID = crypto.randomUUID();
  const stub = env.ANALYSIS.get(env.ANALYSIS.idFromName(analysisID));
  const started = await stub.fetch("https://do/start", {
    method: "POST",
    body: JSON.stringify({ request: body, requestID }),
  });
  if (!started.ok) return errorResponse("internal", "Could not start analysis.", 500);

  return json({ id: analysisID, requestID }, 201);
}

function proxyToSession(
  env: Env,
  analysisID: string,
  method: string,
  doPath: string,
  req: Request,
): Promise<Response> {
  const stub = env.ANALYSIS.get(env.ANALYSIS.idFromName(analysisID));
  return stub.fetch(`https://do${doPath}`, { method, headers: req.headers });
}

// --- helpers ---------------------------------------------------------------

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function errorResponse(code: PublicErrorCode, message: string, status: number): Response {
  const body: PublicError = { error: { code, message } };
  return json(body, status);
}
