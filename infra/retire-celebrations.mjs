#!/usr/bin/env node
// Run after deploying the backend without /celebrate. Dry-run unless --apply.
// Deletes only celebrations/{fixture}/shards/*, their parents, and celebrate/*.
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";

const require = createRequire(new URL("../backend/package.json", import.meta.url));
const { S3Client, ListObjectsV2Command, DeleteObjectsCommand } = require("@aws-sdk/client-s3");
const args = process.argv.slice(2);
const project = args[args.indexOf("--project") + 1];
if (!args.includes("--project") || !["dreamaboutsports-staging", "dreamaboutsports-prod"].includes(project)) {
  throw new Error("Usage: node infra/retire-celebrations.mjs --project dreamaboutsports-{staging|prod} [--apply]");
}
const apply = args.includes("--apply");
const gcloud = (...args) => execFileSync("gcloud", args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();
const token = gcloud("auth", "print-access-token");
async function google(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-Goog-User-Project": project, ...options.headers },
  });
  if (!response.ok) throw new Error(`Google API ${response.status}: ${await response.text()}`);
  return response;
}

// Refuse destructive cleanup while the old public write endpoint is reachable.
const service = JSON.parse(gcloud("run", "services", "describe", "alldayidreamaboutsports-backend",
  "--project", project, "--region", "us-central1", "--format=json"));
if (apply) {
  const response = await fetch(`${service.status.url}/celebrate`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: "{}",
  });
  if (![401, 403, 404].includes(response.status)) {
    throw new Error("The legacy public endpoint is still reachable. Deploy and privatize the service first.");
  }
  await response.arrayBuffer();
}

const root = `projects/${project}/databases/(default)/documents`;
async function listDocuments(collection) {
  const docs = [];
  let pageToken;
  do {
    const query = new URLSearchParams({ pageSize: "300", showMissing: "true", ...(pageToken ? { pageToken } : {}) });
    const response = await google(`https://firestore.googleapis.com/v1/${collection}?${query}`);
    const page = await response.json();
    docs.push(...(page.documents ?? []));
    pageToken = page.nextPageToken;
  } while (pageToken);
  return docs;
}
const parents = await listDocuments(`${root}/celebrations`);
const documentNames = [];
for (const parent of parents) {
  const shards = await listDocuments(`${parent.name}/shards`);
  documentNames.push(...shards.map((doc) => doc.name), parent.name);
}
const bucket = service.spec.template.spec.containers[0].env.find((entry) => entry.name === "R2_BUCKET_SCORES")?.value;
const expectedBucket = project.endsWith("-staging") ? "alldayidreamaboutsports-staging-scores" : "alldayidreamaboutsports-scores";
if (bucket !== expectedBucket) throw new Error("Unexpected scores bucket; refusing cleanup");
const secret = (name) => gcloud("secrets", "versions", "access", "latest", "--secret", name, "--project", project);
const s3 = new S3Client({ region: "auto", endpoint: secret("r2-endpoint"), credentials: {
  accessKeyId: secret("r2-access-key-id"), secretAccessKey: secret("r2-secret-access-key"),
} });
const keys = [];
let continuation;
do {
  const page = await s3.send(new ListObjectsV2Command({ Bucket: bucket, Prefix: "celebrate/", ContinuationToken: continuation }));
  keys.push(...(page.Contents ?? []).map((object) => object.Key));
  continuation = page.NextContinuationToken;
} while (continuation);

const configUrl = `https://firebaseremoteconfig.googleapis.com/v1/projects/${project}/remoteConfig`;
const configResponse = await google(configUrl);
const config = await configResponse.json();
const obsolete = ["celebration_enabled", "celebration_sample_percent"].filter((key) => key in (config.parameters ?? {}));
console.log(JSON.stringify({ project, apply, firestoreDocuments: documentNames.length, r2Objects: keys.length, remoteConfigParameters: obsolete }));
if (apply) {
  for (let i = 0; i < documentNames.length; i += 400) {
    const batch = documentNames.slice(i, i + 400);
    if (batch.some((name) => !name.startsWith(`${root}/celebrations/`))) throw new Error("Invalid delete scope");
    const response = await google(`https://firestore.googleapis.com/v1/${root}:batchWrite`, {
      method: "POST", body: JSON.stringify({ writes: batch.map((name) => ({ delete: name })) }),
    });
    const result = await response.json();
    if (result.status?.some((status) => status.code)) throw new Error("One or more Firestore deletes failed");
  }
  for (let i = 0; i < keys.length; i += 1000) {
    const batch = keys.slice(i, i + 1000);
    if (batch.some((key) => !key.startsWith("celebrate/"))) throw new Error("Invalid R2 delete scope");
    const result = await s3.send(new DeleteObjectsCommand({ Bucket: bucket, Delete: { Objects: batch.map((Key) => ({ Key })) } }));
    if (result.Errors?.length) throw new Error("One or more R2 deletes failed");
  }
  if (obsolete.length) {
    for (const key of obsolete) delete config.parameters[key];
    delete config.version;
    await google(configUrl, { method: "PUT", headers: { "If-Match": configResponse.headers.get("etag") }, body: JSON.stringify(config) });
  }
  // The runtime now only polls/publishes scores and enqueues tasks. Remove its
  // old database and Firebase Admin grants, preserving all other principals.
  const runtime = `serviceAccount:sports-runtime@${project}.iam.gserviceaccount.com`;
  const policy = JSON.parse(gcloud("projects", "get-iam-policy", project, "--format=json"));
  for (const role of ["roles/datastore.user", "roles/firebase.sdkAdminServiceAgent"]) {
    if (policy.bindings?.some((binding) => binding.role === role && !binding.condition && binding.members?.includes(runtime))) {
      gcloud("projects", "remove-iam-policy-binding", project, "--member", runtime,
        "--role", role, "--condition=None", "--quiet");
    }
  }
  console.log("Legacy celebration data removed.");
}
s3.destroy();
