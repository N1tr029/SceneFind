import type { AllowanceReservation, AnalysisRequest, Env, PublicError, PublicErrorCode } from "./types";
import { authenticate, AuthError } from "./auth";
import { attestationStub } from "./attestation";
import {
  getEntitlement,
  reserveAllowance,
  finishAllowance,
} from "./entitlement";
import {
  processAppStoreNotification,
  StoreKitVerificationError,
  verifyStoreKitTransaction,
} from "./appStore";
import { enforceChallengeRateLimit, enforceRateLimits } from "./rateLimit";
import { handleWatchLinks } from "./watchLinks";

export { AnalysisSession } from "./session";
export { AppAttestationRegistry } from "./attestation";
export { EntitlementLedger } from "./entitlement";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const requestID = crypto.randomUUID();
    const startedAt = Date.now();
    try {
      const response = await route(req, env);
      log("request", {
        requestID,
        method: req.method,
        path: new URL(req.url).pathname,
        status: response.status,
        durationMs: Date.now() - startedAt,
      });
      return response;
    } catch (err) {
      if (err instanceof AuthError) return json(err.body, err.status);
      if (err instanceof StoreKitVerificationError) {
        log("storekit_rejected", { requestID, reason: err.message });
        return errorResponse("unauthorized", "The App Store transaction could not be verified.", 401);
      }
      log("unhandled", {
        requestID,
        type: err instanceof Error ? err.name : "unknown",
      });
      return errorResponse("internal", "Unexpected error.", 500);
    }
  },
} satisfies ExportedHandler<Env>;

async function route(req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname;

  if (path === "/healthz" && req.method === "GET") return new Response("ok");
  if (path === "/v1/attest/challenge" && req.method === "POST") {
    if (!(await enforceChallengeRateLimit(req, env))) {
      return errorResponse("rate_limited", "Too many attestation requests.", 429);
    }
    return attestRoute(req, env, "/challenge");
  }
  if (path === "/v1/attest/register" && req.method === "POST") {
    if (!(await enforceChallengeRateLimit(req, env))) {
      return errorResponse("rate_limited", "Too many attestation requests.", 429);
    }
    return attestRoute(req, env, "/register");
  }
  if (path === "/v1/app-store/notifications" && req.method === "POST") {
    await processAppStoreNotification(env, await req.json());
    return new Response(null, { status: 204 });
  }

  if (path === "/v1/analysis" && req.method === "POST") {
    return createAnalysis(req, env);
  }

  const eventsMatch = path.match(/^\/v1\/analysis\/([^/]+)\/events$/);
  if (eventsMatch && req.method === "GET") {
    const identity = await authenticate(req, env);
    if (!(await enforceRateLimits(req, env, identity.installationID))) {
      return errorResponse("rate_limited", "Too many requests.", 429);
    }
    return proxyToSession(env, eventsMatch[1], "GET", "/events", req);
  }

  const analysisMatch = path.match(/^\/v1\/analysis\/([^/]+)$/);
  if (analysisMatch && req.method === "DELETE") {
    const identity = await authenticate(req, env);
    if (!(await enforceRateLimits(req, env, identity.installationID))) {
      return errorResponse("rate_limited", "Too many requests.", 429);
    }
    return proxyToSession(env, analysisMatch[1], "DELETE", "/cancel", req);
  }

  if (path === "/v1/watch-links" && req.method === "GET") {
    const identity = await authenticate(req, env);
    if (!(await enforceRateLimits(req, env, identity.installationID))) {
      return errorResponse("rate_limited", "Too many requests.", 429);
    }
    return handleWatchLinks(req, env);
  }

  if (path === "/v1/entitlement" && req.method === "GET") {
    const identity = await authenticate(req, env);
    if (!(await enforceRateLimits(req, env, identity.installationID))) {
      return errorResponse("rate_limited", "Too many requests.", 429);
    }
    return json(await getEntitlement(env, identity.installationID));
  }

  if (path === "/v1/storekit/transaction" && req.method === "POST") {
    const identity = await authenticate(req, env);
    if (!(await enforceRateLimits(req, env, identity.installationID))) {
      return errorResponse("rate_limited", "Too many requests.", 429);
    }
    const body = await req.json();
    return json(await verifyStoreKitTransaction(env, identity.installationID, body));
  }

  return errorResponse("not_found", "No such route.", 404);
}

async function attestRoute(req: Request, env: Env, targetPath: string): Promise<Response> {
  const body = (await req.json()) as { installationID?: string };
  const installationID = body.installationID?.trim();
  if (!installationID || !/^[0-9a-f-]{36}$/i.test(installationID)) {
    return errorResponse("invalid_request", "A valid installation identity is required.", 400);
  }
  return attestationStub(env, installationID).fetch(`https://attest${targetPath}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function createAnalysis(req: Request, env: Env): Promise<Response> {
  const identity = await authenticate(req, env);
  if (!(await enforceRateLimits(req, env, identity.installationID))) {
    return errorResponse("rate_limited", "Too many analyses. Try again shortly.", 429);
  }

  let body: AnalysisRequest;
  try {
    body = (await req.json()) as AnalysisRequest;
  } catch {
    return errorResponse("invalid_request", "Body must be JSON.", 400);
  }
  const validationError = validateAnalysisRequest(body);
  if (validationError) return errorResponse("invalid_request", validationError, 400);

  const reserved = await reserveAllowance(
    env,
    identity.installationID,
    body.idempotencyKey,
  );
  if (!reserved.response.ok) {
    if (reserved.response.status === 402) {
      return errorResponse("entitlement_exhausted", "No identifications remain in this period.", 402);
    }
    return errorResponse("internal", "Could not reserve allowance.", 500);
  }
  const reservation = await reserved.response.json<AllowanceReservation>();

  const durableID = env.ANALYSIS.idFromName(`${reserved.owner}:${body.idempotencyKey}`);
  const analysisID = durableID.toString();
  const requestID = body.idempotencyKey;
  const stub = env.ANALYSIS.get(durableID);
  const started = await stub.fetch("https://do/start", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      request: body,
      requestID,
      entitlementOwner: reserved.owner,
      reservationID: reservation.reservationID,
    }),
  });
  if (!started.ok) {
    await finishAllowance(env, reserved.owner, reservation.reservationID, false);
    return errorResponse("internal", "Could not start analysis.", 500);
  }

  return json({ id: analysisID, requestID, entitlement: reservation.state }, 201);
}

function validateAnalysisRequest(body: AnalysisRequest): string | null {
  if (!body || typeof body !== "object") return "A request body is required.";
  if (!body.idempotencyKey || body.idempotencyKey.length > 128) {
    return "A valid idempotency key is required.";
  }
  const sources = [body.sourceURL, body.sourceDataBase64, body.sourceText].filter(Boolean);
  if (sources.length !== 1) return "Provide exactly one URL, media item, or text source.";
  if (body.sourceURL) {
    try {
      const url = new URL(body.sourceURL);
      if (url.protocol !== "https:") return "Only HTTPS source URLs are accepted.";
    } catch {
      return "The source URL is invalid.";
    }
  }
  if (body.sourceDataBase64) {
    if (body.sourceDataBase64.length > 10_666_668) {
      return "The selected media is too large.";
    }
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(body.sourceDataBase64)) {
      return "The selected media is not valid Base64.";
    }
    if (!body.sourceMimeType || !/^(video|audio|image)\/[a-z0-9.+-]+$/i.test(body.sourceMimeType)) {
      return "The selected media type is unsupported.";
    }
  }
  return null;
}

function proxyToSession(
  env: Env,
  analysisID: string,
  method: string,
  doPath: string,
  req: Request,
): Promise<Response> {
  let id: DurableObjectId;
  try {
    id = env.ANALYSIS.idFromString(analysisID);
  } catch {
    return Promise.resolve(errorResponse("not_found", "Analysis not found.", 404));
  }
  return env.ANALYSIS.get(id).fetch(`https://do${doPath}`, { method, headers: req.headers });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
    },
  });
}

function errorResponse(code: PublicErrorCode, message: string, status: number): Response {
  const body: PublicError = { error: { code, message } };
  return json(body, status);
}

function log(event: string, fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ event, ...fields }));
}
