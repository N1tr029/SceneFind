import type {
  AllowanceReservation,
  EntitlementPlan,
  EntitlementState,
  EntitlementStatus,
  Env,
} from "./types";

export const PRODUCT_IDS = {
  starter: "com.kavigandham.scenefind.starter.monthly",
  pro: "com.kavigandham.scenefind.pro.monthly",
  lifetime: "com.kavigandham.scenefind.lifetime",
} as const;

const PLAN_ALLOWANCE: Record<EntitlementPlan, number> = {
  freeTrial: 2,
  starter: 10,
  pro: 50,
  lifetime: 10,
};

const RESERVATION_TTL_MS = 5 * 60 * 1_000;

type ReservationStatus = "reserved" | "committed" | "released";

interface ReservationRecord {
  id: string;
  idempotencyKey: string;
  status: ReservationStatus;
  createdAtMs: number;
}

export interface VerifiedTransaction {
  originalTransactionID: string;
  transactionID: string;
  productID: string;
  purchaseDateMs: number;
  expirationDateMs?: number;
  revocationDateMs?: number;
  signedDateMs: number;
  appAccountToken?: string;
  status?: EntitlementStatus;
  gracePeriodExpiresDateMs?: number;
  isInBillingRetryPeriod?: boolean;
}

interface LedgerRecord {
  plan: EntitlementPlan;
  status: EntitlementStatus;
  used: number;
  periodStartMs?: number;
  periodEndMs?: number;
  originalTransactionID?: string;
  latestTransactionID?: string;
  latestSignedDateMs?: number;
  gracePeriodExpiresDateMs?: number;
  reservations: Record<string, ReservationRecord>;
  updatedAtMs: number;
}

function initialLedger(nowMs: number): LedgerRecord {
  return {
    plan: "freeTrial",
    status: "active",
    used: 0,
    reservations: {},
    updatedAtMs: nowMs,
  };
}

export class EntitlementLedger implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(req: Request): Promise<Response> {
    return this.state.blockConcurrencyWhile(() => this.handle(req));
  }

  private async handle(req: Request): Promise<Response> {
    const path = new URL(req.url).pathname;
    const nowMs = Date.now();
    const ledger = await this.load(nowMs);
    this.rollPeriodAndPrune(ledger, nowMs);

    switch (`${req.method} ${path}`) {
      case "GET /state":
        await this.save(ledger);
        return Response.json(publicState(ledger, nowMs));
      case "POST /reserve":
        return this.reserve(req, ledger, nowMs);
      case "POST /commit":
        return this.finishReservation(req, ledger, nowMs, "committed");
      case "POST /release":
        return this.finishReservation(req, ledger, nowMs, "released");
      case "POST /transaction":
        return this.applyTransaction(req, ledger, nowMs);
      default:
        return new Response("not found", { status: 404 });
    }
  }

  private async reserve(
    req: Request,
    ledger: LedgerRecord,
    nowMs: number,
  ): Promise<Response> {
    const body = await jsonBody<{ idempotencyKey?: string }>(req);
    const key = body?.idempotencyKey?.trim();
    if (!key || key.length > 128) {
      return Response.json({ error: "invalid idempotency key" }, { status: 400 });
    }

    const existing = Object.values(ledger.reservations).find(
      (value) => value.idempotencyKey === key,
    );
    if (existing && existing.status !== "released") {
      return Response.json({
        reservationID: existing.id,
        state: publicState(ledger, nowMs),
        duplicate: true,
      } satisfies AllowanceReservation);
    }

    if (!hasActiveAccess(ledger, nowMs) || availableCount(ledger) <= 0) {
      return Response.json(
        { error: "entitlement_exhausted", state: publicState(ledger, nowMs) },
        { status: 402 },
      );
    }

    const reservation: ReservationRecord = {
      id: crypto.randomUUID(),
      idempotencyKey: key,
      status: "reserved",
      createdAtMs: nowMs,
    };
    ledger.reservations[reservation.id] = reservation;
    ledger.updatedAtMs = nowMs;
    await this.save(ledger);
    return Response.json({
      reservationID: reservation.id,
      state: publicState(ledger, nowMs),
      duplicate: false,
    } satisfies AllowanceReservation);
  }

  private async finishReservation(
    req: Request,
    ledger: LedgerRecord,
    nowMs: number,
    status: Extract<ReservationStatus, "committed" | "released">,
  ): Promise<Response> {
    const body = await jsonBody<{ reservationID?: string }>(req);
    const reservation = body?.reservationID
      ? ledger.reservations[body.reservationID]
      : undefined;
    if (!reservation) {
      return Response.json({ error: "reservation not found" }, { status: 404 });
    }

    // Idempotent completion: a duplicated callback never consumes twice.
    if (reservation.status === "reserved") {
      reservation.status = status;
      if (status === "committed") ledger.used += 1;
      ledger.updatedAtMs = nowMs;
      await this.save(ledger);
    }
    return Response.json(publicState(ledger, nowMs));
  }

  private async applyTransaction(
    req: Request,
    ledger: LedgerRecord,
    nowMs: number,
  ): Promise<Response> {
    const transaction = await jsonBody<VerifiedTransaction>(req);
    if (!transaction || !planForProduct(transaction.productID)) {
      return Response.json({ error: "unsupported product" }, { status: 400 });
    }
    if (
      ledger.latestSignedDateMs !== undefined &&
      transaction.signedDateMs < ledger.latestSignedDateMs
    ) {
      return Response.json(publicState(ledger, nowMs));
    }

    const plan = planForProduct(transaction.productID)!;
    const nextPeriod = periodFor(plan, transaction, nowMs);
    const periodChanged =
      ledger.plan !== plan ||
      ledger.periodStartMs !== nextPeriod.startMs ||
      ledger.periodEndMs !== nextPeriod.endMs;

    if (periodChanged) {
      ledger.used = 0;
      ledger.reservations = {};
    }
    ledger.plan = plan;
    ledger.periodStartMs = nextPeriod.startMs;
    ledger.periodEndMs = nextPeriod.endMs;
    ledger.originalTransactionID = transaction.originalTransactionID;
    ledger.latestTransactionID = transaction.transactionID;
    ledger.latestSignedDateMs = transaction.signedDateMs;
    ledger.gracePeriodExpiresDateMs = transaction.gracePeriodExpiresDateMs;
    ledger.status = statusForTransaction(plan, transaction, nowMs);
    ledger.updatedAtMs = nowMs;
    await this.save(ledger);
    return Response.json(publicState(ledger, nowMs));
  }

  private async load(nowMs: number): Promise<LedgerRecord> {
    return (await this.state.storage.get<LedgerRecord>("ledger")) ?? initialLedger(nowMs);
  }

  private save(ledger: LedgerRecord): Promise<void> {
    return this.state.storage.put("ledger", ledger);
  }

  private rollPeriodAndPrune(ledger: LedgerRecord, nowMs: number): void {
    for (const [id, reservation] of Object.entries(ledger.reservations)) {
      if (
        reservation.status === "reserved" &&
        reservation.createdAtMs + RESERVATION_TTL_MS <= nowMs
      ) {
        reservation.status = "released";
      }
      if (
        reservation.status === "released" &&
        reservation.createdAtMs + 24 * 60 * 60 * 1_000 <= nowMs
      ) {
        delete ledger.reservations[id];
      }
    }

    if (ledger.plan === "lifetime") {
      const month = utcCalendarMonth(nowMs);
      if (ledger.periodStartMs !== month.startMs || ledger.periodEndMs !== month.endMs) {
        ledger.periodStartMs = month.startMs;
        ledger.periodEndMs = month.endMs;
        ledger.used = 0;
        ledger.reservations = {};
        ledger.updatedAtMs = nowMs;
      }
    }
  }
}

export async function resolveLedgerOwner(env: Env, installationID: string): Promise<string> {
  return (await env.RATE_LIMIT.get(`entitlement-owner:${installationID}`)) ?? installationID;
}

export function ledgerStub(env: Env, owner: string): DurableObjectStub {
  return env.ENTITLEMENTS.get(env.ENTITLEMENTS.idFromName(owner));
}

export async function getEntitlement(
  env: Env,
  installationID: string,
): Promise<EntitlementState> {
  const owner = await resolveLedgerOwner(env, installationID);
  const response = await ledgerStub(env, owner).fetch("https://ledger/state");
  return response.json<EntitlementState>();
}

export async function reserveAllowance(
  env: Env,
  installationID: string,
  idempotencyKey: string,
): Promise<{ owner: string; response: Response }> {
  const owner = await resolveLedgerOwner(env, installationID);
  const response = await ledgerStub(env, owner).fetch("https://ledger/reserve", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ idempotencyKey }),
  });
  return { owner, response };
}

export async function finishAllowance(
  env: Env,
  owner: string,
  reservationID: string,
  success: boolean,
): Promise<void> {
  await ledgerStub(env, owner).fetch(success ? "https://ledger/commit" : "https://ledger/release", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ reservationID }),
  });
}

export async function applyVerifiedTransaction(
  env: Env,
  installationID: string | null,
  transaction: VerifiedTransaction,
): Promise<EntitlementState> {
  const mappingKey = `transaction-owner:${transaction.originalTransactionID}`;
  let owner = await env.RATE_LIMIT.get(mappingKey);
  if (!owner) {
    if (!installationID) throw new Error("transaction owner is unknown");
    if (transaction.appAccountToken?.toLowerCase() !== installationID.toLowerCase()) {
      throw new Error("first transaction claim is not bound to this installation");
    }
    owner = await resolveLedgerOwner(env, installationID);
    await env.RATE_LIMIT.put(mappingKey, owner);
  }
  if (installationID) {
    await env.RATE_LIMIT.put(`entitlement-owner:${installationID}`, owner);
  }
  const response = await ledgerStub(env, owner).fetch("https://ledger/transaction", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(transaction),
  });
  if (!response.ok) throw new Error("ledger rejected transaction");
  return response.json<EntitlementState>();
}

function planForProduct(productID: string): EntitlementPlan | null {
  switch (productID) {
    case PRODUCT_IDS.starter:
      return "starter";
    case PRODUCT_IDS.pro:
      return "pro";
    case PRODUCT_IDS.lifetime:
      return "lifetime";
    default:
      return null;
  }
}

function periodFor(
  plan: EntitlementPlan,
  transaction: VerifiedTransaction,
  nowMs: number,
): { startMs?: number; endMs?: number } {
  if (plan === "lifetime") return utcCalendarMonth(nowMs);
  if (plan === "freeTrial") return {};
  return {
    startMs: transaction.purchaseDateMs,
    endMs: transaction.expirationDateMs,
  };
}

function statusForTransaction(
  plan: EntitlementPlan,
  transaction: VerifiedTransaction,
  nowMs: number,
): EntitlementStatus {
  if (transaction.status) return transaction.status;
  if (transaction.revocationDateMs !== undefined) return "refunded";
  if (plan === "lifetime") return "active";
  if (
    transaction.gracePeriodExpiresDateMs !== undefined &&
    transaction.gracePeriodExpiresDateMs > nowMs
  ) {
    return "gracePeriod";
  }
  if (transaction.isInBillingRetryPeriod) return "billingRetry";
  return transaction.expirationDateMs !== undefined && transaction.expirationDateMs > nowMs
    ? "active"
    : "expired";
}

function utcCalendarMonth(nowMs: number): { startMs: number; endMs: number } {
  const date = new Date(nowMs);
  const startMs = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1);
  const endMs = Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1);
  return { startMs, endMs };
}

function hasActiveAccess(ledger: LedgerRecord, nowMs: number): boolean {
  if (ledger.status === "active") {
    return ledger.plan === "freeTrial" || ledger.plan === "lifetime" ||
      (ledger.periodEndMs !== undefined && ledger.periodEndMs > nowMs);
  }
  return ledger.status === "gracePeriod" &&
    ledger.gracePeriodExpiresDateMs !== undefined &&
    ledger.gracePeriodExpiresDateMs > nowMs;
}

function availableCount(ledger: LedgerRecord): number {
  const held = Object.values(ledger.reservations).filter(
    (reservation) => reservation.status === "reserved",
  ).length;
  return Math.max(0, PLAN_ALLOWANCE[ledger.plan] - ledger.used - held);
}

function publicState(ledger: LedgerRecord, nowMs: number): EntitlementState {
  const active = hasActiveAccess(ledger, nowMs);
  const allowance = PLAN_ALLOWANCE[ledger.plan];
  const remaining = active ? availableCount(ledger) : 0;
  return {
    plan: ledger.plan,
    status: ledger.status,
    allowance,
    remaining,
    periodStart: iso(ledger.periodStartMs),
    periodEnd: iso(ledger.periodEndMs),
    renewsAt:
      ledger.plan === "starter" || ledger.plan === "pro"
        ? iso(ledger.periodEndMs)
        : null,
    canAnalyze: active && remaining > 0,
    lastSyncedAt: new Date(ledger.updatedAtMs).toISOString(),
  };
}

function iso(value?: number): string | null {
  return value === undefined ? null : new Date(value).toISOString();
}

async function jsonBody<T>(req: Request): Promise<T | null> {
  try {
    return (await req.json()) as T;
  } catch {
    return null;
  }
}
