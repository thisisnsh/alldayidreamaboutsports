import type { NextFunction, Request, Response } from "express";
import { OAuth2Client } from "google-auth-library";
import { env } from "./env.js";

const googleClient = new OAuth2Client();

/** Service authentication is independent of app users or sign-in. */
export function validateServiceAuthentication(): void {
  void env.serviceUrl;
  void env.schedulerServiceAccount;
  void env.deployServiceAccount;
}

/**
 * Guards /internal/* — accepts only Google-signed OIDC tokens minted by our
 * Cloud Scheduler service account. Cloud Run IAM also requires an authorized
 * invoker; this check restricts operational routes to the scheduler identity.
 */
export function requireSchedulerOidc(req: Request, res: Response, next: NextFunction): void {
  requireOidc(req, res, next, () => [env.schedulerServiceAccount]);
}

/** Deployment smoke checks may inspect health without invoking poller routes. */
export function requireHealthOidc(req: Request, res: Response, next: NextFunction): void {
  requireOidc(req, res, next, () => [env.schedulerServiceAccount, env.deployServiceAccount]);
}

function requireOidc(req: Request, res: Response, next: NextFunction, identities: () => string[]): void {
  let audience: string;
  let allowedIdentities: string[];
  try {
    audience = env.serviceUrl;
    allowedIdentities = identities();
  } catch {
    res.status(503).json({ error: "service authentication is not configured" });
    return;
  }
  const token = req.headers.authorization?.match(/^Bearer ([^\s]+)$/i)?.[1];
  if (!token || token.split(".").length !== 3) {
    res.status(401).json({ error: "missing token" });
    return;
  }
  googleClient
    .verifyIdToken({ idToken: token, audience })
    .then((ticket) => {
      const p = ticket.getPayload();
      if (p?.email && allowedIdentities.includes(p.email) && p.email_verified === true) next();
      else res.status(403).json({ error: "wrong identity" });
    })
    .catch(() => res.status(401).json({ error: "invalid token" }));
}
