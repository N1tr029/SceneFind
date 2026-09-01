import type {
  JWSRenewalInfoDecodedPayload,
  JWSTransactionDecodedPayload,
  SignedDataVerifier,
} from "@apple/app-store-server-library";
import { Buffer } from "node:buffer";
import { applyVerifiedTransaction, PRODUCT_IDS, type VerifiedTransaction } from "./entitlement";
import type { EntitlementState, EntitlementStatus, Env } from "./types";

// Public Apple roots downloaded from Apple PKI. Keeping the DER certificates in
// source removes a network dependency from the verification hot path.
const APPLE_ROOT_CA_G2 =
  "MIIFkjCCA3qgAwIBAgIIAeDltYNno+AwDQYJKoZIhvcNAQEMBQAwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEcyMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxMDA5WhcNMzkwNDMwMTgxMDA5WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzIxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgREkhI2imKScUcx+xuM23+TfvgHN6sXuI2pyT5f1BrTM65MFQn5bPW7SXmMLYFN14UIhHF6Kob0vuy0gmVOKTvKkmMXT5xZgM4+xb1hYjkWpIMBDLyyED7Ul+f9sDx47pFoFDVEovy3d6RhiPw9bZyLgHaC/YuOQhfGaFjQQscp5TBhsRTL3b2CtcM0YM/GlMZ81fVJ3/8E7j4ko380yhDPLVoACVdJ2LT3VXdRCCQgzWTxb+4Gftr49wIQuavbfqeQMpOhYV4SbHXw8EwOTKrfl+q04tvny0aIWhwZ7Oj8ZhBbZF8+NfbqOdfIRqMM78xdLe40fTgIvS/cjTf94FNcX1RoeKz8NMoFnNvzcytN31O661A4T+B/fc9Cj6i8b0xlilZ3MIZgIxbdMYs0xBTJh0UT8TUgWY8h2czJxQI6bR3hDRSj4n4aJgXv8O7qhOTH11UL6jHfPsNFL4VPSQ08prcdUFmIrQB1guvkJ4M6mL4m1k8COKWNORj3rw31OsMiANDC1CvoDTdUE0V+1ok2Az6DGOeHwOx4e7hqkP0ZmUoNwIx7wHHHtHMn23KVDpA287PT0aLSmWaasZobNfMmRtHsHLDd4/E92GcdB/O/WuhwpyUgquUoue9G7q5cDmVF8Up8zlYNPXEpMZ7YLlmQ1A/bmH8DvmGqmAMQ0uVAgMBAAGjQjBAMB0GA1UdDgQWBBTEmRNsGAPCe8CjoA1/coB6HHcmjTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQwFAAOCAgEAUabz4vS4PZO/Lc4Pu1vhVRROTtHlznldgX/+tvCHM/jvlOV+3Gp5pxy+8JS3ptEwnMgNCnWefZKVfhidfsJxaXwU6s+DDuQUQp50DhDNqxq6EWGBeNjxtUVAeKuowM77fWM3aPbn+6/Gw0vsHzYmE1SGlHKy6gLti23kDKaQwFd1z4xCfVzmMX3zybKSaUYOiPjjLUKyOKimGY3xn83uamW8GrAlvacp/fQ+onVJv57byfenHmOZ4VxG/5IFjPoeIPmGlFYl5bRXOJ3riGQUIUkhOb9iZqmxospvPyFgxYnURTbImHy99v6ZSYA7LNKmp4gDBDEZt7Y6YUX6yfIjyGNzv1aJMbDZfGKnexWoiIqrOEDCzBL/FePwN983csvMmOa/orz6JopxVtfnJBtIRD6e/J/JzBrsQzwBvDR4yGn1xuZW7AYJNpDrFEobXsmII9oDMJELuDY++ee1KG++P+w8j2Ud5cAeh6Squpj9kuNsJnfdBrRkBof0Tta6SqoWqPQFZ2aWuuJVecMsXUmPgEkrihLHdoBR37q9ZV0+N0djMenl9MU/S60EinpxLK8JQzcPqOMyT/RFtm2XNuyE9QoB6he7hY1Ck3DDUOUUi78/w0EP3SIEIwiKum1xRKtzCTrJ+VKACd+66eYWyi4uTLLT3OUEVLLUNIAytbwPF+E=";
const APPLE_ROOT_CA_G3 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

const supportedProducts = new Set<string>(Object.values(PRODUCT_IDS));
type AppleEnvironment = "Sandbox" | "Production";

export class StoreKitVerificationError extends Error {}

export async function verifyStoreKitTransaction(
  env: Env,
  installationID: string,
  body: unknown,
): Promise<EntitlementState> {
  const signedTransaction = value(body, "signedTransaction");
  if (!signedTransaction) throw new StoreKitVerificationError("Missing signed transaction.");
  const environment = decodedEnvironment(signedTransaction);
  const verifier = await verifierFor(env, environment);
  const decoded = await verifier.verifyAndDecodeTransaction(signedTransaction);
  const transaction = normalizedTransaction(decoded);
  return applyVerifiedTransaction(env, installationID, transaction);
}

export async function processAppStoreNotification(env: Env, body: unknown): Promise<void> {
  const signedPayload = value(body, "signedPayload");
  if (!signedPayload) throw new StoreKitVerificationError("Missing signed notification.");
  const verifier = await verifierFor(env, decodedEnvironment(signedPayload));
  const notification = await verifier.verifyAndDecodeNotification(signedPayload);
  if (notification.notificationType === "TEST") return;
  const signedTransaction = notification.data?.signedTransactionInfo;
  if (!signedTransaction) return;

  const decoded = await verifier.verifyAndDecodeTransaction(signedTransaction);
  let renewal: JWSRenewalInfoDecodedPayload | undefined;
  if (notification.data?.signedRenewalInfo) {
    renewal = await verifier.verifyAndDecodeRenewalInfo(notification.data.signedRenewalInfo);
  }
  const transaction = normalizedTransaction(decoded, {
    status: notificationStatus(notification.notificationType, notification.data?.status),
    gracePeriodExpiresDateMs: renewal?.gracePeriodExpiresDate,
    isInBillingRetryPeriod: renewal?.isInBillingRetryPeriod,
  });
  await applyVerifiedTransaction(env, null, transaction);
}

function normalizedTransaction(
  decoded: JWSTransactionDecodedPayload,
  overrides: Partial<VerifiedTransaction> = {},
): VerifiedTransaction {
  const originalTransactionID = decoded.originalTransactionId;
  const transactionID = decoded.transactionId;
  const productID = decoded.productId;
  const purchaseDateMs = decoded.purchaseDate;
  const signedDateMs = decoded.signedDate;
  if (
    !originalTransactionID ||
    !transactionID ||
    !productID ||
    purchaseDateMs === undefined ||
    signedDateMs === undefined ||
    !supportedProducts.has(productID)
  ) {
    throw new StoreKitVerificationError("Transaction is incomplete or uses an unknown product.");
  }
  return {
    originalTransactionID,
    transactionID,
    productID,
    purchaseDateMs,
    expirationDateMs: decoded.expiresDate,
    revocationDateMs: decoded.revocationDate,
    signedDateMs,
    appAccountToken: decoded.appAccountToken,
    ...overrides,
  };
}

function notificationStatus(
  notificationType?: string,
  status?: number,
): EntitlementStatus | undefined {
  if (notificationType === "REVOKE") return "revoked";
  if (notificationType === "REFUND") return "refunded";
  return entitlementStatus(status);
}

async function verifierFor(
  env: Env,
  environment: AppleEnvironment,
): Promise<SignedDataVerifier> {
  // Apple's package initializes its crypto dependency during import. Loading it
  // inside the request keeps that work out of Cloudflare's global scope.
  const { Environment, SignedDataVerifier } = await import("@apple/app-store-server-library");
  const roots = [
    Buffer.from(APPLE_ROOT_CA_G2, "base64"),
    Buffer.from(APPLE_ROOT_CA_G3, "base64"),
  ];
  const onlineChecks = env.APPLE_ENABLE_ONLINE_CHECKS === "1";
  if (environment === Environment.PRODUCTION) {
    const appAppleID = Number(env.APPLE_APP_ID);
    if (!Number.isSafeInteger(appAppleID) || appAppleID <= 0) {
      throw new StoreKitVerificationError("APPLE_APP_ID is not configured.");
    }
    return new SignedDataVerifier(
      roots,
      onlineChecks,
      Environment.PRODUCTION,
      env.APPLE_BUNDLE_ID,
      appAppleID,
    );
  }
  if (environment === Environment.SANDBOX) {
    return new SignedDataVerifier(
      roots,
      onlineChecks,
      Environment.SANDBOX,
      env.APPLE_BUNDLE_ID,
    );
  }
  throw new StoreKitVerificationError("Only Apple sandbox and production transactions are accepted.");
}

function decodedEnvironment(jws: string): AppleEnvironment {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new StoreKitVerificationError("Malformed JWS.");
  try {
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")) as {
      environment?: string;
      data?: { environment?: string };
    };
    const raw = payload.environment ?? payload.data?.environment;
    if (raw === "Production") return "Production";
    if (raw === "Sandbox") return "Sandbox";
  } catch {
    // The selected verifier still performs the authoritative validation.
  }
  throw new StoreKitVerificationError("Unsupported transaction environment.");
}

function entitlementStatus(status?: number): EntitlementStatus | undefined {
  switch (status) {
    case 1:
      return "active";
    case 2:
      return "expired";
    case 3:
      return "billingRetry";
    case 4:
      return "gracePeriod";
    case 5:
      return "revoked";
    default:
      return undefined;
  }
}

function value(body: unknown, key: string): string | null {
  if (!body || typeof body !== "object") return null;
  const result = (body as Record<string, unknown>)[key];
  return typeof result === "string" && result.length > 0 ? result : null;
}
