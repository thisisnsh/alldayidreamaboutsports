import { createReadStream } from "node:fs";
import { readdir, stat } from "node:fs/promises";
import path from "node:path";
import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var ${name}`);
  return value;
}

function shouldUpload(file: string): boolean {
  return file === "appcast.xml" || /\.(dmg|delta|html)$/.test(file);
}

function contentType(file: string): string {
  if (file.endsWith(".dmg")) return "application/x-apple-diskimage";
  if (file.endsWith(".delta")) return "application/octet-stream";
  if (file.endsWith(".html")) return "text/html; charset=utf-8";
  if (file.endsWith(".xml")) return "application/xml; charset=utf-8";
  return "application/octet-stream";
}

function cacheControl(file: string): string {
  if (file === "appcast.xml") return "public, max-age=300, stale-while-revalidate=3600";
  return "public, max-age=31536000, immutable";
}

async function uploadDirectory(releasesDir: string, bucket: string): Promise<void> {
  const client = new S3Client({
    region: "auto",
    endpoint: required("R2_ENDPOINT"),
    credentials: {
      accessKeyId: required("R2_ACCESS_KEY_ID"),
      secretAccessKey: required("R2_SECRET_ACCESS_KEY"),
    },
  });

  const entries = await readdir(releasesDir);
  for (const file of entries.filter(shouldUpload).sort()) {
    const fullPath = path.join(releasesDir, file);
    const info = await stat(fullPath);
    if (!info.isFile()) continue;

    await client.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: file,
        Body: createReadStream(fullPath),
        ContentLength: info.size,
        ContentType: contentType(file),
        CacheControl: cacheControl(file),
      }),
    );
    console.log(`uploaded ${file}`);
  }
}

const [releasesDir, bucket] = process.argv.slice(2);
if (!releasesDir || !bucket) {
  console.error("usage: upload-r2.ts <releases-dir> <bucket>");
  process.exit(1);
}

uploadDirectory(releasesDir, bucket).catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
