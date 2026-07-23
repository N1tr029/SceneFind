// Installation identity + App Attest / DeviceCheck verification.
//
// STATUS: stub. This establishes the shape and the fail-closed default. The
// real implementation must verify the App Attest assertion against Apple's
// root before any provider work runs (see docs/PRODUCTION_BACKEND.md, "Abuse
// And Reliability"). Until that lands, non-dev requests are rejected so we
// never expose the proxy unauthenticated.

import type { Env, PublicError } from "./types";

export interface Identity {
  installationID: string;
}

export class AuthError extends Error {
  constructor(public readonly body: PublicError, public readonly status = 401) {
    super(body.error.message);
  }
}

// Headers the client is expected to send:
//   X-SceneFind-Install:  opaque per-install id (created + stored in Keychain)
//   X-SceneFind-Assertion: base64 App Attest assertion over the request token
//   X-SceneFind-Token:     short-lived signed request token
export async function authenticate(req: Request, env: Env): Promise<Identity> {
  const installationID = req.headers.get("X-SceneFind-Install")?.trim();

  if (env.ALLOW_INSECURE_DEV_AUTH === "1") {
    // Local development only — wrangler.toml keeps this "0" in every deployed env.
    return { installationID: installationID || "dev-install" };
  }

  const assertion = req.headers.get("X-SceneFind-Assertion");
  if (!installationID || !assertion) {
    throw new AuthError({
      error: { code: "unauthorized", message: "Missing attestation." },
    });
  }

  // TODO: verify App Attest assertion (fall back to DeviceCheck), bind it to the
  // request token, and reject replays. Until implemented, fail closed.
  throw new AuthError({
    error: { code: "unauthorized", message: "Attestation verification not yet enabled." },
  });
}
