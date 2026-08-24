import { afterEach, describe, expect, it, vi } from "vitest";
import {
  applyVerifiedTransaction,
  EntitlementLedger,
  PRODUCT_IDS,
  resolveLedgerOwner,
  type VerifiedTransaction,
} from "../src/entitlement";
import type { EntitlementState, Env } from "../src/types";

class FakeStorage {
  private readonly values = new Map<string, unknown>();

  async get<T>(key: string): Promise<T | undefined> {
    return structuredClone(this.values.get(key)) as T | undefined;
  }

  async put<T>(key: string, value: T): Promise<void> {
    this.values.set(key, structuredClone(value));
  }
}

class FakeState {
  readonly storage = new FakeStorage();
  private queue: Promise<unknown> = Promise.resolve();

  blockConcurrencyWhile<T>(callback: () => Promise<T>): Promise<T> {
    const result = this.queue.then(callback);
    this.queue = result.then(() => undefined, () => undefined);
    return result;
  }
}

class FakeKV {
  private readonly values = new Map<string, string>();

  async get(key: string): Promise<string | null> {
    return this.values.get(key) ?? null;
  }

  async put(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }
}

class FakeLedgerNamespace {
  private readonly ledgers = new Map<string, EntitlementLedger>();

  idFromName(name: string): DurableObjectId {
    return { toString: () => name } as DurableObjectId;
  }

  get(id: DurableObjectId): DurableObjectStub {
    const name = id.toString();
    let ledger = this.ledgers.get(name);
    if (!ledger) {
      ledger = makeLedger();
      this.ledgers.set(name, ledger);
    }
    return {
      fetch: (input: RequestInfo | URL, init?: RequestInit) =>
        ledger!.fetch(new Request(input, init)),
    } as DurableObjectStub;
  }
}

describe("EntitlementLedger", () => {
  afterEach(() => vi.useRealTimers());

  it("atomically allows only two concurrent free-trial reservations", async () => {
    const ledger = makeLedger();
    const responses = await Promise.all(
      ["one", "two", "three"].map((key) => reserve(ledger, key)),
    );
    expect(responses.map((response) => response.status).sort()).toEqual([200, 200, 402]);
  });

  it("deduplicates a request and commits a success exactly once", async () => {
    const ledger = makeLedger();
    const first = await reserve(ledger, "same-request");
    const duplicate = await reserve(ledger, "same-request");
    const firstBody = await first.json() as { reservationID: string; duplicate: boolean };
    const duplicateBody = await duplicate.json() as { reservationID: string; duplicate: boolean };
    expect(duplicateBody).toMatchObject({ reservationID: firstBody.reservationID, duplicate: true });

    await finish(ledger, "/commit", firstBody.reservationID);
    await finish(ledger, "/commit", firstBody.reservationID);
    const state = await getState(ledger);
    expect(state.remaining).toBe(1);
  });

  it("does not consume failed or cancelled work", async () => {
    const ledger = makeLedger();
    const response = await reserve(ledger, "failed-request");
    const body = await response.json() as { reservationID: string };
    await finish(ledger, "/release", body.reservationID);
    const state = await getState(ledger);
    expect(state.remaining).toBe(2);
  });

  it("applies Starter billing periods and resets only on renewal", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-10T12:00:00Z"));
    const ledger = makeLedger();
    const first = transaction({
      productID: PRODUCT_IDS.starter,
      transactionID: "txn-1",
      purchaseDateMs: Date.parse("2026-08-01T00:00:00Z"),
      expirationDateMs: Date.parse("2026-09-01T00:00:00Z"),
      signedDateMs: Date.parse("2026-08-01T00:00:01Z"),
    });
    await applyTransaction(ledger, first);
    const reserved = await reserve(ledger, "starter-use");
    const reservation = await reserved.json() as { reservationID: string };
    await finish(ledger, "/commit", reservation.reservationID);
    expect((await getState(ledger)).remaining).toBe(9);

    await applyTransaction(ledger, { ...first, signedDateMs: first.signedDateMs + 1_000 });
    expect((await getState(ledger)).remaining).toBe(9);

    await applyTransaction(ledger, transaction({
      productID: PRODUCT_IDS.starter,
      transactionID: "txn-2",
      purchaseDateMs: Date.parse("2026-09-01T00:00:00Z"),
      expirationDateMs: Date.parse("2026-10-01T00:00:00Z"),
      signedDateMs: Date.parse("2026-09-01T00:00:01Z"),
    }));
    expect((await getState(ledger)).remaining).toBe(10);
  });

  it("revokes refunded lifetime access", async () => {
    const ledger = makeLedger();
    const purchase = transaction({
      productID: PRODUCT_IDS.lifetime,
      transactionID: "lifetime-1",
      purchaseDateMs: Date.now() - 1_000,
      signedDateMs: Date.now(),
    });
    await applyTransaction(ledger, purchase);
    expect(await getState(ledger)).toMatchObject({ plan: "lifetime", remaining: 10, canAnalyze: true });
    await applyTransaction(ledger, {
      ...purchase,
      signedDateMs: purchase.signedDateMs + 1_000,
      revocationDateMs: purchase.signedDateMs + 500,
    });
    expect(await getState(ledger)).toMatchObject({ status: "refunded", remaining: 0, canAnalyze: false });
  });

  it("preserves an explicit App Store revocation status", async () => {
    const ledger = makeLedger();
    await applyTransaction(ledger, transaction({
      productID: PRODUCT_IDS.lifetime,
      transactionID: "lifetime-revoked",
      purchaseDateMs: Date.now() - 1_000,
      signedDateMs: Date.now(),
      revocationDateMs: Date.now(),
      status: "revoked",
    }));
    expect(await getState(ledger)).toMatchObject({
      status: "revoked",
      remaining: 0,
      canAnalyze: false,
    });
  });

  it("restores another device into the original transaction's shared ledger", async () => {
    const firstInstall = "11111111-1111-4111-8111-111111111111";
    const secondInstall = "22222222-2222-4222-8222-222222222222";
    const env = makeEnv();
    const purchase = transaction({
      productID: PRODUCT_IDS.lifetime,
      transactionID: "lifetime-cross-device",
      purchaseDateMs: Date.now() - 1_000,
      signedDateMs: Date.now(),
      appAccountToken: firstInstall,
    });

    await applyVerifiedTransaction(env, firstInstall, purchase);
    const restored = await applyVerifiedTransaction(env, secondInstall, purchase);

    expect(restored).toMatchObject({ plan: "lifetime", remaining: 10, canAnalyze: true });
    expect(await resolveLedgerOwner(env, secondInstall)).toBe(firstInstall);
  });

  it("rejects a mismatched first transaction claim", async () => {
    const env = makeEnv();
    await expect(applyVerifiedTransaction(env, "33333333-3333-4333-8333-333333333333", transaction({
      productID: PRODUCT_IDS.lifetime,
      transactionID: "stolen-first-claim",
      purchaseDateMs: Date.now() - 1_000,
      signedDateMs: Date.now(),
      appAccountToken: "44444444-4444-4444-8444-444444444444",
    }))).rejects.toThrow("first transaction claim");
  });
});

function makeLedger(): EntitlementLedger {
  return new EntitlementLedger(new FakeState() as unknown as DurableObjectState);
}

function makeEnv(): Env {
  return {
    RATE_LIMIT: new FakeKV(),
    ENTITLEMENTS: new FakeLedgerNamespace(),
  } as unknown as Env;
}

function reserve(ledger: EntitlementLedger, idempotencyKey: string): Promise<Response> {
  return ledger.fetch(new Request("https://ledger/reserve", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ idempotencyKey }),
  }));
}

function finish(
  ledger: EntitlementLedger,
  path: "/commit" | "/release",
  reservationID: string,
): Promise<Response> {
  return ledger.fetch(new Request(`https://ledger${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ reservationID }),
  }));
}

async function getState(ledger: EntitlementLedger): Promise<EntitlementState> {
  const response = await ledger.fetch(new Request("https://ledger/state"));
  return response.json<EntitlementState>();
}

function applyTransaction(
  ledger: EntitlementLedger,
  value: VerifiedTransaction,
): Promise<Response> {
  return ledger.fetch(new Request("https://ledger/transaction", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(value),
  }));
}

function transaction(
  overrides: Partial<VerifiedTransaction> & Pick<VerifiedTransaction, "productID" | "transactionID" | "purchaseDateMs" | "signedDateMs">,
): VerifiedTransaction {
  return {
    originalTransactionID: "original-1",
    ...overrides,
  };
}
