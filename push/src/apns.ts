import { connect, type ClientHttp2Session } from "node:http2";
import { createPrivateKey, sign } from "node:crypto";
import type { Config } from "./config.js";
import type { Delivery } from "./model.js";

export interface SendResult { status: number; reason?: string; retryAfter?: number }
export interface Sender { send(delivery: Delivery): Promise<SendResult> }
export function classify(result: SendResult): "ok" | "invalid-token" | "retry" | "permanent" {
  if (result.status === 200) return "ok";
  if (result.status === 410 || ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].includes(result.reason ?? "")) return "invalid-token";
  if (result.status === 429 || result.status >= 500 || result.status === 0 || result.reason === "ExpiredProviderToken") return "retry";
  return "permanent";
}

export class APNs implements Sender {
  private session?: ClientHttp2Session;
  private jwt?: { value: string; at: number };
  private key: ReturnType<typeof createPrivateKey>;
  constructor(private config: Config) {
    this.key = createPrivateKey(config.APNS_PRIVATE_KEY.replace(/\\n/g, "\n"));
    if (this.key.asymmetricKeyType !== "ec" || this.key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
      throw new Error("APNs requires a P-256 signing key");
    }
  }
  private token(): string {
    const now = Math.floor(Date.now() / 1000);
    if (this.jwt && now - this.jwt.at < 3000) return this.jwt.value;
    const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: this.config.APNS_KEY_ID })).toString("base64url");
    const body = Buffer.from(JSON.stringify({ iss: this.config.APNS_TEAM_ID, iat: now })).toString("base64url");
    const data = `${header}.${body}`;
    const signature = sign("sha256", Buffer.from(data), { key: this.key, dsaEncoding: "ieee-p1363" }).toString("base64url");
    this.jwt = { value: `${data}.${signature}`, at: now }; return this.jwt.value;
  }
  private connection(): ClientHttp2Session {
    if (!this.session || this.session.closed || this.session.destroyed) {
      const host = this.config.APNS_ENVIRONMENT === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
      const session = connect(`https://${host}`);
      session.on("error", () => { session.destroy(); });
      session.on("goaway", () => { if (this.session === session) this.session = undefined; session.close(); });
      this.session = session;
    }
    return this.session;
  }
  async send(delivery: Delivery): Promise<SendResult> {
    if (this.config.DRY_RUN === "true") return { status: 200 };
    const payload = JSON.stringify(delivery.payload);
    if (Buffer.byteLength(payload) > 4096) return { status: 413, reason: "PayloadTooLarge" };
    return new Promise(resolve => {
      let finished = false, status = 0, body = "", retryAfter: number | undefined;
      const done = (result: SendResult) => { if (!finished) { finished = true; clearTimeout(timer); resolve(result); } };
      const timer = setTimeout(() => { stream?.close(); done({ status: 0 }); }, 8000);
      let stream: ReturnType<ClientHttp2Session["request"]> | undefined;
      try {
        stream = this.connection().request({
          ":method": "POST", ":path": `/3/device/${delivery.token}`,
          authorization: `bearer ${this.token()}`, "apns-push-type": delivery.kind,
          "apns-topic": this.config.APNS_BUNDLE_ID + (delivery.kind === "liveactivity" ? ".push-type.liveactivity" : ""),
          "apns-priority": String(delivery.priority), "apns-expiration": String(Math.floor(delivery.expiresAt / 1000)),
          "apns-collapse-id": delivery.collapseId,
          "content-type": "application/json",
        });
        stream.on("response", headers => {
          status = Number(headers[":status"]);
          const value = Number(headers["retry-after"]); if (Number.isFinite(value) && value > 0) retryAfter = value;
        });
        stream.setEncoding("utf8");
        stream.on("data", (chunk: string) => { body += chunk; if (body.length > 8192) { stream?.close(); done({ status: 0 }); } });
        stream.on("error", () => done({ status: 0 }));
        stream.on("end", () => {
          let reason: string | undefined;
          try { reason = JSON.parse(body).reason; } catch { /* success may have no body */ }
          if (reason === "ExpiredProviderToken") this.jwt = undefined;
          done({ status, reason, retryAfter });
        });
        stream.end(payload);
      } catch { done({ status: 0 }); }
    });
  }
  close() { this.session?.close(); }
}
