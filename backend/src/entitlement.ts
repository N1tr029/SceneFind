// Authoritative allowance + subscription state.
//
// This replaces the app's local DailyUsageLimiter, which the production doc
// flags as "not a security boundary". STATUS: minimal KV-backed stub — real
// implementation must verify StoreKit transactions with Apple and track
// per-install / per-account / per-IP counters with idempotency keys.

import type { Env, EntitlementState } from "./types";

const FREE_ALLOWANCE = 1;

export async function getEntitlement(
  env: Env,
  installationID: string,
): Promise<EntitlementState> {
  const premium = (await env.RATE_LIMIT.get(`premium:${installationID}`)) === "1";
  const usedRaw = await env.RATE_LIMIT.get(`used:${installationID}`);
  const used = usedRaw ? parseInt(usedRaw, 10) || 0 : 0;
  return {
    freeRemaining: premium ? Number.MAX_SAFE_INTEGER : Math.max(0, FREE_ALLOWANCE - used),
    isPremium: premium,
    renewsAt: null,
    fairUseLimited: false,
  };
}

// Commit one free success (called by the pipeline only when a useful result is
// returned — reserve-then-commit, so failed analyses don't burn the allowance).
export async function commitFreeUse(env: Env, installationID: string): Promise<void> {
  const usedRaw = await env.RATE_LIMIT.get(`used:${installationID}`);
  const used = usedRaw ? parseInt(usedRaw, 10) || 0 : 0;
  await env.RATE_LIMIT.put(`used:${installationID}`, String(used + 1));
}

export async function verifyStoreKitTransaction(
  env: Env,
  installationID: string,
  _body: unknown,
): Promise<EntitlementState> {
  // TODO: verify the signed StoreKit transaction (JWS) against Apple's keys,
  // confirm the product id + expiry, then mark premium. Until then this is a
  // no-op that just returns current state.
  return getEntitlement(env, installationID);
}
