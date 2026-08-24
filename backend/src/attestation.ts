import { Buffer } from "node:buffer";
import { X509Certificate } from "node:crypto";
import cbor from "cbor";
import { verifyAssertion, verifyAttestation } from "node-app-attest";
import type { Env } from "./types";

const CHALLENGE_TTL_MS = 5 * 60 * 1_000;

interface ChallengeRecord {
  value: string;
  expiresAtMs: number;
}

interface KeyRecord {
  keyID: string;
  publicKey: string;
  signCount: number;
  environment: string;
  receipt: string;
}

interface RegistryRecord {
  installationID: string;
  challenges: Record<string, ChallengeRecord>;
  key?: KeyRecord;
}

export interface AppAttestClientData {
  installationID: string;
  keyID: string;
  challenge: string;
  method: string;
  path: string;
  bodySHA256: string;
  timestampMs: number;
}

export class AppAttestationRegistry implements DurableObject {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {}

  async fetch(req: Request): Promise<Response> {
    return this.state.blockConcurrencyWhile(() => this.handle(req));
  }

  private async handle(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname;
    switch (`${req.method} ${path}`) {
      case "POST /challenge":
        return this.challenge(req);
      case "POST /register":
        return this.register(req);
      case "POST /assert":
        return this.assert(req);
      default:
        return new Response("not found", { status: 404 });
    }
  }

  private async challenge(req: Request): Promise<Response> {
    const body = await bodyAs<{ installationID?: string }>(req);
    const installationID = body?.installationID?.trim();
    if (!validInstallationID(installationID)) {
      return Response.json({ error: "invalid installation" }, { status: 400 });
    }
    const nowMs = Date.now();
    const record = await this.load(installationID!);
    pruneChallenges(record, nowMs);
    const value = randomChallenge();
    record.challenges[value] = { value, expiresAtMs: nowMs + CHALLENGE_TTL_MS };
    await this.save(record);
    return Response.json({ challenge: value, expiresAt: new Date(nowMs + CHALLENGE_TTL_MS) });
  }

  private async register(req: Request): Promise<Response> {
    const body = await bodyAs<{
      installationID?: string;
      keyID?: string;
      challenge?: string;
      attestation?: string;
    }>(req);
    if (
      !validInstallationID(body?.installationID) ||
      !body?.keyID ||
      !body.challenge ||
      !body.attestation
    ) {
      return Response.json({ error: "invalid registration" }, { status: 400 });
    }
    const record = await this.load(body.installationID);
    if (record.key && record.key.keyID !== body.keyID) {
      return Response.json({ error: "attestation key already registered" }, { status: 409 });
    }
    if (!consumeChallenge(record, body.challenge, Date.now())) {
      return Response.json({ error: "challenge expired" }, { status: 401 });
    }
    try {
      validateAttestationCertificates(Buffer.from(body.attestation, "base64"));
      const result = verifyAttestation({
        attestation: Buffer.from(body.attestation, "base64"),
        challenge: body.challenge,
        keyId: body.keyID,
        bundleIdentifier: this.env.APPLE_BUNDLE_ID,
        teamIdentifier: this.env.APPLE_TEAM_ID,
        allowDevelopmentEnvironment: this.env.APP_ATTEST_ALLOW_DEVELOPMENT === "1",
      });
      record.key = {
        keyID: result.keyId,
        publicKey: result.publicKey,
        signCount: 0,
        environment: result.environment,
        receipt: Buffer.isBuffer(result.receipt)
          ? result.receipt.toString("base64")
          : String(result.receipt ?? ""),
      };
      await this.save(record);
      return new Response(null, { status: 204 });
    } catch {
      return Response.json({ error: "attestation rejected" }, { status: 401 });
    }
  }

  private async assert(req: Request): Promise<Response> {
    const body = await bodyAs<{
      installationID?: string;
      keyID?: string;
      assertion?: string;
      clientDataBase64?: string;
    }>(req);
    if (
      !validInstallationID(body?.installationID) ||
      !body?.keyID ||
      !body.assertion ||
      !body.clientDataBase64
    ) {
      return Response.json({ error: "invalid assertion" }, { status: 400 });
    }
    const record = await this.load(body.installationID);
    if (!record.key || record.key.keyID !== body.keyID) {
      return Response.json({ error: "key not registered" }, { status: 401 });
    }
    const clientData = Buffer.from(body.clientDataBase64, "base64");
    let decoded: AppAttestClientData;
    try {
      decoded = JSON.parse(clientData.toString("utf8")) as AppAttestClientData;
    } catch {
      return Response.json({ error: "invalid client data" }, { status: 400 });
    }
    if (
      decoded.installationID !== body.installationID ||
      decoded.keyID !== body.keyID ||
      !consumeChallenge(record, decoded.challenge, Date.now())
    ) {
      return Response.json({ error: "challenge rejected" }, { status: 401 });
    }
    try {
      const result = verifyAssertion({
        assertion: Buffer.from(body.assertion, "base64"),
        payload: clientData,
        publicKey: record.key.publicKey,
        bundleIdentifier: this.env.APPLE_BUNDLE_ID,
        teamIdentifier: this.env.APPLE_TEAM_ID,
        signCount: record.key.signCount,
      });
      if (!Number.isSafeInteger(result.signCount) || result.signCount <= record.key.signCount) {
        throw new Error("non-monotonic assertion counter");
      }
      record.key.signCount = result.signCount;
      await this.save(record);
      return new Response(null, { status: 204 });
    } catch {
      return Response.json({ error: "assertion rejected" }, { status: 401 });
    }
  }

  private async load(installationID: string): Promise<RegistryRecord> {
    return (await this.state.storage.get<RegistryRecord>("registry")) ?? {
      installationID,
      challenges: {},
    };
  }

  private save(record: RegistryRecord): Promise<void> {
    return this.state.storage.put("registry", record);
  }
}

function validateAttestationCertificates(attestation: Buffer): void {
  const decoded = cbor.decodeAllSync(attestation);
  const x5c = decoded.length === 1 ? decoded[0]?.attStmt?.x5c : undefined;
  if (!Array.isArray(x5c) || x5c.length !== 2 || !x5c.every(Buffer.isBuffer)) {
    throw new Error("invalid attestation certificate chain");
  }
  const nowMs = Date.now();
  for (const value of x5c as Buffer[]) {
    const certificate = new X509Certificate(value);
    const validFromMs = Date.parse(certificate.validFrom);
    const validToMs = Date.parse(certificate.validTo);
    if (!Number.isFinite(validFromMs) || !Number.isFinite(validToMs) ||
        nowMs < validFromMs || nowMs > validToMs) {
      throw new Error("expired attestation certificate");
    }
  }
}

export function attestationStub(env: Env, installationID: string): DurableObjectStub {
  return env.APP_ATTEST.get(env.APP_ATTEST.idFromName(installationID));
}

function validInstallationID(value?: string): value is string {
  return typeof value === "string" && /^[0-9a-f-]{36}$/i.test(value);
}

function randomChallenge(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Buffer.from(bytes).toString("base64url");
}

function pruneChallenges(record: RegistryRecord, nowMs: number): void {
  for (const [key, challenge] of Object.entries(record.challenges)) {
    if (challenge.expiresAtMs <= nowMs) delete record.challenges[key];
  }
}

function consumeChallenge(record: RegistryRecord, challenge: string, nowMs: number): boolean {
  pruneChallenges(record, nowMs);
  const found = record.challenges[challenge];
  if (!found) return false;
  delete record.challenges[challenge];
  return true;
}

async function bodyAs<T>(req: Request): Promise<T | null> {
  try {
    return (await req.json()) as T;
  } catch {
    return null;
  }
}
