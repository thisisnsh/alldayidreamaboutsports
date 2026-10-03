import type { NextFunction, Request, Response } from "express";
import { OAuth2Client } from "google-auth-library";
import { env } from "./env.js";

const googleClient = new OAuth2Client();

/**
 * Guards /internal/* — accepts only Google-signed OIDC tokens minted by our
 * Cloud Scheduler service account (the service itself stays public for the app
 * API, so internal routes do their own authentication).
 */
export function requireSchedulerOidc(req: Request, res: Response, next: NextFunction): void {
  const token = req.headers.authorization?.replace(/^Bearer /, "");
  if (!token) {
    res.status(401).json({ error: "missing token" });
    return;
  }
  googleClient
    .verifyIdToken({ idToken: token, audience: process.env.SERVICE_URL })
    .then((ticket) => {
      const p = ticket.getPayload();
      if (p?.email === env.schedulerServiceAccount && p.email_verified) next();
      else res.status(403).json({ error: "wrong identity" });
    })
    .catch(() => res.status(401).json({ error: "invalid token" }));
}
