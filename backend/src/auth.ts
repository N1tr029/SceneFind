import { Buffer } from "node:buffer";
import { attestationStub, type AppAttestClientData } from "./attestation";
import type { Env, PublicError } from "./types";

export interface Identity {
  installationID: string;
}

export class AuthError extends Error {
  constructor(public readonly body: PublicError, public readonly status = 401) {
    super(body.error.message);
  }
}

// Every protected request is bound to a fresh server challenge, the exact HTTP
// method/path/body hash, the installation, and the attested Secure Enclave key.
export async function authenticate(req: Request, env: Env): Promise<Identity> {
  const installationID = req.headers.get("X-SceneFind-Install")?.trim();
  if (!validInstallationID(installationID)) {
    throw unauthorized("Missing installation identity.");
  }

  const url = new URL(req.url);
  if (
    env.ALLOW_INSECURE_DEV_AUTH === "1" &&
    (url.hostname === "localhost" || url.hostname === "127.0.0.1")
  ) {
    return { installationID };
  }

  const keyID = req.headers.get("X-SceneFind-Key-ID")?.trim();
  const assertion = req.headers.get("X-SceneFind-Assertion")?.trim();
  const clientDataBase64 = req.headers.get("X-SceneFind-Client-Data")?.trim();
  if (!keyID || !assertion || !clientDataBase64) {
    throw unauthorized("App Attest assertion required.", "attestation_required");
  }

  let clientData: AppAttestClientData;
  try {
    clientData = JSON.parse(Buffer.from(clientDataBase64, "base64").toString("utf8"));
  } catch {
    throw unauthorized("Malformed App Attest client data.");
  }
  const nowMs = Date.now();
  const expectedBodyHash = await bodySHA256(req.clone());
  if (
    clientData.installationID !== installationID ||
    clientData.keyID !== keyID ||
    clientData.method !== req.method ||
    clientData.path !== url.pathname ||
    clientData.bodySHA256 !== expectedBodyHash ||
    Math.abs(nowMs - clientData.timestampMs) > 5 * 60 * 1_000
  ) {
    throw unauthorized("App Attest request binding is invalid.");
  }

  const response = await attestationStub(env, installationID).fetch("https://attest/assert", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ installationID, keyID, assertion, clientDataBase64 }),
  });
  if (!response.ok) throw unauthorized("App Attest assertion rejected.");
  return { installationID };
}

async function bodySHA256(req: Request): Promise<string> {
  const bytes = await req.arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Buffer.from(digest).toString("base64url");
}

function validInstallationID(value?: string): value is string {
  return typeof value === "string" && /^[0-9a-f-]{36}$/i.test(value);
}

function unauthorized(
  message: string,
  code: "unauthorized" | "attestation_required" = "unauthorized",
): AuthError {
  return new AuthError({ error: { code, message } });
}
