import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { env } from "./env.js";

/** Cloudflare R2 via its S3-compatible API. Objects carry their own cache TTLs. */
export class R2 {
  private readonly client: S3Client;
  private readonly bucket: string;

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
}
