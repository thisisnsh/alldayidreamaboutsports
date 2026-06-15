import { GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { env } from "./env.js";
import type { MatchState } from "./types.js";

export interface VersionedMatchState {
  state: MatchState | null;
  etag: string | null;
}

export class R2ConflictError extends Error {}

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

  async putJson(key: string, value: unknown, maxAgeSeconds: number): Promise<void> {
    await this.client.send(
      new PutObjectCommand({
        Bucket: this.bucket,
        Key: key,
        Body: JSON.stringify(value),
        ContentType: "application/json",
        CacheControl: `public, max-age=${maxAgeSeconds}`,
      }),
    );
  }

  /** Skips the PUT when the value matches the last write of this key in-process. */
  async putJsonIfChanged(key: string, value: unknown, maxAgeSeconds: number): Promise<void> {
    const body = JSON.stringify(value);
    if (this.writeCache.get(key) === body) return;
    await this.putJson(key, value, maxAgeSeconds);
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
