import { generateKeyPairSync, sign } from "node:crypto";
import { OAuth2Client } from "google-auth-library";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { requireHealthOidc, requireSchedulerOidc, validateServiceAuthentication } from "../src/auth.js";

const audience = "https://backend.example.invalid";
const scheduler = "sports-scheduler@test-project.iam.gserviceaccount.com";
const deploy = "sports-deploy@test-project.iam.gserviceaccount.com";
const keys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");

function token(overrides: Record<string, unknown> = {}): string {
  const now = Math.floor(Date.now() / 1000);
  const data = `${encode({ alg: "RS256", kid: "test" })}.${encode({
    iss: "https://accounts.google.com", aud: audience, email: scheduler,
    email_verified: true, iat: now, exp: now + 3600, ...overrides,
  })}`;
  return `${data}.${sign("RSA-SHA256", Buffer.from(data), keys.privateKey).toString("base64url")}`;
}

function authorize(authorization?: string, health = false): Promise<number> {
  return new Promise((resolve) => {
    let code = 200;
    const response = { status(value: number) { code = value; return this; }, json() { resolve(code); } };
    (health ? requireHealthOidc : requireSchedulerOidc)(
      { headers: { authorization } } as never, response as never, () => resolve(200),
    );
  });
}

describe("service OIDC authentication", () => {
  beforeEach(() => {
    vi.stubEnv("SERVICE_URL", audience);
    vi.stubEnv("GCP_PROJECT_ID", "test-project");
    vi.stubEnv("SCHEDULER_SA_EMAIL", scheduler);
    vi.stubEnv("DEPLOY_SA_EMAIL", deploy);
    // Use only a local issuer certificate. Signature, expiry, issuer, audience
    // and email checks still run through the real Google verification library.
    vi.spyOn(OAuth2Client.prototype, "getFederatedSignonCertsAsync").mockResolvedValue({
      certs: { test: keys.publicKey.export({ type: "spki", format: "pem" }) }, format: "PEM",
    } as never);
  });
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); });

  it("accepts the scheduler on operational routes", async () => {
    expect(await authorize(`Bearer ${token()}`)).toBe(200);
  });
  it("allows the deploy identity only on health", async () => {
    const credential = `Bearer ${token({ email: deploy })}`;
    expect(await authorize(credential)).toBe(403);
    expect(await authorize(credential, true)).toBe(200);
  });
  it.each([
    [{ aud: "https://another.example.invalid" }, 401],
    [{ iss: "https://untrusted.example.invalid" }, 401],
    [{ email: "attacker@example.invalid" }, 403],
    [{ email_verified: false }, 403],
    [{ email_verified: "true" }, 403],
    [{ iat: 1, exp: 3600 }, 401],
  ])("rejects invalid claims %j", async (claims, status) => {
    expect(await authorize(`Bearer ${token(claims)}`)).toBe(status);
  });
  it("rejects a tampered signature", async () => {
    const [header, payload] = token().split(".");
    expect(await authorize(`Bearer ${header}.${payload}.${Buffer.alloc(256).toString("base64url")}`)).toBe(401);
  });
  it.each([undefined, "garbage", "Basic a.b.c"])("rejects malformed authorization %s", async (header) => {
    expect(await authorize(header)).toBe(401);
  });
  it.each(["", "http://backend.example.invalid", "https://backend.example.invalid/path"])(
    "fails closed and refuses startup for invalid audience %s", async (value) => {
      vi.stubEnv("SERVICE_URL", value);
      expect(() => validateServiceAuthentication()).toThrow();
      expect(await authorize(`Bearer ${token({ aud: "https://another.example.invalid" })}`)).toBe(503);
      expect(OAuth2Client.prototype.getFederatedSignonCertsAsync).not.toHaveBeenCalled();
    },
  );
});
