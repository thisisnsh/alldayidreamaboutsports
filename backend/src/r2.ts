import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { env } from "./env.js";
import type { MatchState } from "./types.js";

export interface VersionedMatchState {
  state: MatchState | null;
  etag: string | null;
}

export class R2ConflictError extends Error {}

/**
 * Cache-Control for the two live tiers. The zone cache rule serves users from
 * the edge and revalidates with R2 at most once per `max-age` per object — the
 * §0 invariant. `stale-while-revalidate` lets the edge serve the stale copy
 * during that revalidation so a user never waits on origin. EVERY R2 write must
 * set one of these (or a long TTL); a header-less object bypasses the cache.
 */
export const CACHE_CONTROL_LIVE = "public, max-age=5, stale-while-revalidate=25";
/** Long TTL for rarely-changing schedule/catalog files (12h). */
export const CACHE_CONTROL_LONG = "public, max-age=43200";

/** Cloudflare R2 via its S3-compatible API. Objects carry their own cache TTLs. */
export class R2 {
  private readonly client: S3Client;
  private readonly bucket: string;
  /** Last-written body per key; best-effort (per-instance, empty on cold start). */
  private readonly writeCache = new Map<string, string>();

  constructor(client?: S3Client, bucket?: string) {
    this.bucket = bucket ?? env.r2.scoresBucket;
    this.client =
      client ??
      new S3Client({
        region: "auto",
        endpoint: env.r2.endpoint,
        credentials: {
          accessKeyId: env.r2.accessKeyId,
          secretAccessKey: env.r2.secretAccessKey,
        },
      });
  }

  /**
   * Writes a JSON object with an EXPLICIT `Cache-Control` (§0: every object must
   * carry one or the zone cache rule bypasses it). Callers pass a full header
   * string (e.g. `CACHE_CONTROL_LIVE` / `CACHE_CONTROL_LONG`).
   */
  async putJson(key: string, value: unknown, cacheControl: string): Promise<void> {
    await this.client.send(
      new PutObjectCommand({
        Bucket: this.bucket,
        Key: key,
        Body: JSON.stringify(value),
        ContentType: "application/json",
        CacheControl: cacheControl,
      }),
    );
  }

  /** Skips the PUT when the value matches the last write of this key in-process. */
  async putJsonIfChanged(key: string, value: unknown, cacheControl: string): Promise<void> {
    const body = JSON.stringify(value);
    if (this.writeCache.get(key) === body) return;
    await this.putJson(key, value, cacheControl);
    this.writeCache.set(key, body);
  }

  async getJson<T>(key: string): Promise<T | null> {
    try {
      const response = await this.client.send(new GetObjectCommand({ Bucket: this.bucket, Key: key }));
      return JSON.parse(await response.Body!.transformToString()) as T;
    } catch (error) {
      if (["NoSuchKey", "NotFound"].includes((error as { name?: string }).name ?? "")) return null;
      throw error;
    }
  }
}

/** R2 comparison state stored under matches/ in the scores bucket. */
export class R2MatchStateStore {
  private readonly client: S3Client;
  private readonly bucket: string;

  constructor(client?: S3Client, bucket?: string) {
    this.bucket = bucket ?? env.r2.scoresBucket;
    this.client = client ?? new S3Client({
      region: "auto",
      endpoint: env.r2.endpoint,
      credentials: {
        accessKeyId: env.r2.accessKeyId,
        secretAccessKey: env.r2.secretAccessKey,
      },
    });
  }

  private key(fixtureId: number): string {
    return `matches/${fixtureId}.json`;
  }

  async load(fixtureId: number): Promise<VersionedMatchState> {
    try {
      const response = await this.client.send(new GetObjectCommand({
        Bucket: this.bucket,
        Key: this.key(fixtureId),
      }));
      return {
        state: JSON.parse(await response.Body!.transformToString()) as MatchState,
        etag: response.ETag ?? null,
      };
    } catch (error) {
      if (["NoSuchKey", "NotFound"].includes((error as { name?: string }).name ?? "")) {
        return { state: null, etag: null };
      }
      throw error;
    }
  }

  async save(state: MatchState, etag: string | null): Promise<void> {
    try {
      await this.client.send(new PutObjectCommand({
        Bucket: this.bucket,
        Key: this.key(state.fixtureId),
        Body: JSON.stringify(state),
        ContentType: "application/json",
        CacheControl: CACHE_CONTROL_LIVE,
        ...(etag ? { IfMatch: etag } : { IfNoneMatch: "*" }),
      }));
    } catch (error) {
      if ((error as { name?: string }).name === "PreconditionFailed") {
        throw new R2ConflictError(`fixture ${state.fixtureId} state changed concurrently`);
      }
      throw error;
    }
  }
}
