import type { Env } from "./types";

interface RateRecord {
  count: number;
  resetAtMs: number;
}

export async function enforceRateLimits(
  req: Request,
  env: Env,
  installationID: string,
): Promise<boolean> {
  const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
  const [installAllowed, ipAllowed] = await Promise.all([
    consume(env, `rl:install:${installationID}`, 30, 60),
    consume(env, `rl:ip:${ip}`, 120, 60),
  ]);
  return installAllowed && ipAllowed;
}

export async function enforceChallengeRateLimit(req: Request, env: Env): Promise<boolean> {
  const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
  return consume(env, `rl:challenge:${ip}`, 60, 60);
}

async function consume(
  env: Env,
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<boolean> {
  const nowMs = Date.now();
  const existing = await env.RATE_LIMIT.get<RateRecord>(key, "json");
  const record = !existing || existing.resetAtMs <= nowMs
    ? { count: 0, resetAtMs: nowMs + windowSeconds * 1_000 }
    : existing;
  if (record.count >= limit) return false;
  record.count += 1;
  await env.RATE_LIMIT.put(key, JSON.stringify(record), {
    expirationTtl: Math.max(60, Math.ceil((record.resetAtMs - nowMs) / 1_000)),
  });
  return true;
}
