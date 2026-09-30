#!/usr/bin/env node
// Read-only App Store Connect preflight for a SceneFind submission.
//
// Reads nothing but GETs: it never changes a price, a product, or a version.
// Run it before any write, because the live listing is a production surface and
// the submission runbook's record of it has already drifted once — the product
// table there still carried the launch prices weeks after they were re-cut.
//
// Wants ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (the .p8 contents) in the
// environment. The key needs Admin or App Manager to *write* later; a
// Developer-role key reads fine here and then fails on the writes, so the role
// is worth knowing before you count on it.
//
//   node scripts/asc-preflight.mjs

import { createSign } from "node:crypto";

const APP_ID = "6792423118";
const HOST = "https://api.appstoreconnect.apple.com";

/** What the paywall draws and the listing now advertises. The script reports
 *  drift against this, so it is the one place to correct if the plans move. */
const WANTED = {
  "com.kavigandham.scenefind.starter.monthly": { name: "Starter", price: "4.99", period: "monthly" },
  "com.kavigandham.scenefind.pro.monthly": { name: "Pro", price: "19.99", period: "monthly" },
  "com.kavigandham.scenefind.starter.yearly": { name: "Starter Yearly", price: "49.99", period: "yearly" },
  "com.kavigandham.scenefind.pro.yearly": { name: "Pro Yearly", price: "199.99", period: "yearly" },
};
/** Retired: still honoured for existing owners, must not be on sale. */
const RETIRED = "com.kavigandham.scenefind.lifetime";

function token() {
  const { ASC_KEY_ID: kid, ASC_ISSUER_ID: iss, ASC_PRIVATE_KEY: pem } = process.env;
  const missing = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"].filter((k) => !process.env[k]);
  if (missing.length) {
    console.error(`Missing ${missing.join(", ")}.`);
    console.error("Add them to the environment (title-bar cloud menu -> Edit), then start a new session.");
    process.exit(2);
  }
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const body = `${b64({ alg: "ES256", kid, typ: "JWT" })}.${b64({
    iss, iat: now, exp: now + 600, aud: "appstoreconnect-v1",
  })}`;
  // ASC wants a JOSE signature (raw r||s), not the DER that Node signs by default.
  const signer = createSign("sha256");
  signer.update(body);
  const key = pem.includes("\\n") ? pem.replace(/\\n/g, "\n") : pem;
  const sig = signer.sign({ key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${body}.${sig}`;
}

const JWT = token();

async function get(path) {
  const res = await fetch(`${HOST}${path}`, { headers: { Authorization: `Bearer ${JWT}` } });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = null; }
  if (!res.ok) {
    const detail = json?.errors?.map((e) => e.detail || e.title).join("; ") || text.slice(0, 200);
    return { ok: false, status: res.status, detail };
  }
  return { ok: true, status: res.status, json };
}

function line(ok, text) {
  console.log(`  ${ok === null ? "?" : ok ? "OK  " : "GAP "} ${text}`);
}

const app = await get(`/v1/apps/${APP_ID}`);
if (!app.ok) {
  console.error(`\nAuth or access failed: HTTP ${app.status} — ${app.detail}`);
  if (app.status === 401) console.error("A 401 here is the key itself: wrong key id, issuer, or a .p8 that lost its newlines.");
  process.exit(1);
}
console.log(`\nApp: ${app.json.data.attributes.name} (${app.json.data.attributes.bundleId})\n`);

console.log("Subscriptions");
const groups = await get(`/v1/apps/${APP_ID}/subscriptionGroups`);
const seen = new Map();
if (!groups.ok) {
  line(null, `could not read subscription groups: HTTP ${groups.status} — ${groups.detail}`);
} else {
  for (const g of groups.json.data) {
    const subs = await get(`/v1/subscriptionGroups/${g.id}/subscriptions?limit=200`);
    if (!subs.ok) { line(null, `group ${g.id}: HTTP ${subs.status} — ${subs.detail}`); continue; }
    for (const s of subs.json.data) seen.set(s.attributes.productId, { id: s.id, attrs: s.attributes, group: g.id });
  }
  for (const [pid, want] of Object.entries(WANTED)) {
    const found = seen.get(pid);
    if (!found) { line(false, `${want.name} (${pid}) does not exist — must be created`); continue; }
    const state = found.attrs.state;
    const prices = await get(`/v1/subscriptions/${found.id}/prices?include=subscriptionPricePoint&filter[territory]=USA&limit=10`);
    let live = "unknown";
    if (prices.ok) {
      const pt = prices.json.included?.find((i) => i.type === "subscriptionPricePoints");
      live = pt?.attributes?.customerPrice ?? "none set";
    }
    const priceOk = String(live) === want.price;
    line(priceOk, `${want.name} (${pid}) state=${state} price=${live}${priceOk ? "" : ` — want ${want.price}`}`);
  }
  const retired = seen.get(RETIRED);
  if (retired) line(retired.attrs.state !== "APPROVED", `Lifetime present, state=${retired.attrs.state} — must be off sale, not deleted`);
  const extra = [...seen.keys()].filter((p) => !(p in WANTED) && p !== RETIRED);
  if (extra.length) line(null, `also present, not on the paywall: ${extra.join(", ")}`);
}

console.log("\nVersions");
const versions = await get(`/v1/apps/${APP_ID}/appStoreVersions?limit=5&fields[appStoreVersions]=versionString,appStoreState,createdDate`);
if (!versions.ok) {
  line(null, `could not read versions: HTTP ${versions.status} — ${versions.detail}`);
} else {
  const found103 = versions.json.data.find((v) => v.attributes.versionString === "1.0.3");
  for (const v of versions.json.data.slice(0, 5)) {
    console.log(`  ${v.attributes.versionString.padEnd(8)} ${v.attributes.appStoreState}`);
  }
  line(Boolean(found103), found103 ? "1.0.3 exists" : "1.0.3 not created yet");
}

console.log("\nBuilds (newest 5)");
const builds = await get(`/v1/builds?filter[app]=${APP_ID}&limit=5&sort=-uploadedDate&fields[builds]=version,uploadedDate,processingState,expired`);
if (!builds.ok) {
  line(null, `could not read builds: HTTP ${builds.status} — ${builds.detail}`);
} else {
  for (const b of builds.json.data) {
    const a = b.attributes;
    console.log(`  build ${String(a.version).padEnd(5)} ${a.processingState.padEnd(10)} ${a.expired ? "expired" : "valid"}  ${a.uploadedDate}`);
  }
}

console.log("\nRead-only: nothing above was changed.");
