import type { Env } from "./types";

/*
 * Abuse limits for signed app calls and App Attest challenges.
 *
 * These counters used to live in KV, which wrote a record on every request.
 * Workers Free allows 1,000 KV writes a day and every put throws past that, so
 * a busy day would have failed every authenticated request until UTC midnight.
 * Workers Rate Limiting bindings keep the counters at the edge and cost no KV
 * writes. They are per Cloudflare location and eventually consistent, which is
 * fine here: App Attest is what keeps unknown clients out, and these limits only
 * blunt a single install or address hammering the API.
 */

export async function enforceRateLimits(
  req: Request,
  env: Env,
  installationID: string,
): Promise<boolean> {
  const [installAllowed, ipAllowed] = await Promise.all([
    allow(env.INSTALL_RATE_LIMITER, `install:${installationID}`),
    allow(env.IP_RATE_LIMITER, `ip:${clientIP(req)}`),
  ]);
  return installAllowed && ipAllowed;
}

export async function enforceChallengeRateLimit(req: Request, env: Env): Promise<boolean> {
  return allow(env.CHALLENGE_RATE_LIMITER, `challenge:${clientIP(req)}`);
}

/** Fails open. A missing binding or a limiter error must not turn into an
 *  outage of identification itself, which is what the KV version risked. */
async function allow(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  if (!limiter) return true;
  try {
    const { success } = await limiter.limit({ key });
    return success;
  } catch {
    return true;
  }
}

function clientIP(req: Request): string {
  return req.headers.get("CF-Connecting-IP") ?? "unknown";
}
