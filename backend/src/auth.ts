import type { NextFunction, Request, Response } from "express";
import { OAuth2Client } from "google-auth-library";
import { jwtVerify, SignJWT } from "jose";
import { env } from "./env.js";

export interface SessionUser {
  sub: string;
  email: string | null;
  name: string | null;
  photoURL: string | null;
}

const SESSION_TTL = "30d";
const ISSUER = "alldayidreamaboutsports-backend";

function secretKey(): Uint8Array {
  return new TextEncoder().encode(env.sessionJwtSecret);
}

export async function signSession(user: SessionUser): Promise<string> {
  return new SignJWT({ email: user.email, name: user.name, photoURL: user.photoURL })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(user.sub)
    .setIssuer(ISSUER)
    .setIssuedAt()
    .setExpirationTime(SESSION_TTL)
    .sign(secretKey());
}

export async function verifySession(token: string): Promise<SessionUser> {
  const { payload } = await jwtVerify(token, secretKey(), { issuer: ISSUER });
  return {
    sub: payload.sub as string,
    email: (payload.email as string | null) ?? null,
    name: (payload.name as string | null) ?? null,
    photoURL: (payload.photoURL as string | null) ?? null,
  };
}

const googleClient = new OAuth2Client();

/** Verifies the Google ID token from GoogleSignIn on the Mac. Free at any scale. */
export async function verifyGoogleIdToken(idToken: string): Promise<SessionUser> {
  const ticket = await googleClient.verifyIdToken({
    idToken,
    audience: env.googleOauthClientId,
  });
  const p = ticket.getPayload();
  if (!p?.sub) throw new Error("Google token has no subject");
  return {
    sub: p.sub,
    email: p.email ?? null,
    name: p.name ?? null,
    photoURL: p.picture ?? null,
  };
}

declare module "express-serve-static-core" {
  interface Request {
    user?: SessionUser;
  }
}

export function requireSession(req: Request, res: Response, next: NextFunction): void {
  const token = req.headers.authorization?.replace(/^Bearer /, "");
  if (!token) {
    res.status(401).json({ error: "missing token" });
    return;
  }
  verifySession(token)
    .then((user) => {
      req.user = user;
      next();
    })
    .catch(() => res.status(401).json({ error: "invalid token" }));
}

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
