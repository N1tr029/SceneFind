import { describe, expect, it } from "vitest";
import { enforceChallengeRateLimit, enforceRateLimits } from "../src/rateLimit";
import type { Env } from "../src/types";

function limiter(success: boolean, keys: string[]) {
  return {
    limit: async ({ key }: { key: string }) => {
      keys.push(key);
      return { success };
    },
  };
}

const failingKV = {
  get: async () => { throw new Error("KV get() limit exceeded for the day."); },
  put: async () => { throw new Error("KV put() limit exceeded for the day."); },
};

const request = new Request("https://worker.example/v1/analysis", {
  headers: { "CF-Connecting-IP": "203.0.113.9" },
});

describe("rate limits", () => {
  it("checks the install and the address without touching KV", async () => {
    const keys: string[] = [];
    const env = {
      RATE_LIMIT: failingKV,
      INSTALL_RATE_LIMITER: limiter(true, keys),
      IP_RATE_LIMITER: limiter(true, keys),
    } as unknown as Env;

    await expect(enforceRateLimits(request, env, "install-1")).resolves.toBe(true);
    expect(keys.sort()).toEqual(["install:install-1", "ip:203.0.113.9"]);
  });

  it("denies when either limiter is exhausted", async () => {
    const env = {
      INSTALL_RATE_LIMITER: limiter(false, []),
      IP_RATE_LIMITER: limiter(true, []),
    } as unknown as Env;

    await expect(enforceRateLimits(request, env, "install-1")).resolves.toBe(false);
  });

  it("limits attestation challenges per address", async () => {
    const keys: string[] = [];
    const env = { CHALLENGE_RATE_LIMITER: limiter(false, keys) } as unknown as Env;

    await expect(enforceChallengeRateLimit(request, env)).resolves.toBe(false);
    expect(keys).toEqual(["challenge:203.0.113.9"]);
  });

  it("fails open when a binding is missing or the limiter errors", async () => {
    const broken = { limit: async () => { throw new Error("limiter unavailable"); } };
    const env = {
      RATE_LIMIT: failingKV,
      INSTALL_RATE_LIMITER: broken,
      CHALLENGE_RATE_LIMITER: broken,
    } as unknown as Env;

    await expect(enforceRateLimits(request, env, "install-1")).resolves.toBe(true);
    await expect(enforceChallengeRateLimit(request, env)).resolves.toBe(true);
  });
});
