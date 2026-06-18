function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var ${name}`);
  return value;
}

async function purgeFile(url: string): Promise<void> {
  const zoneId = required("CLOUDFLARE_ZONE_ID");
  const token = required("CLOUDFLARE_API_TOKEN");
  const response = await fetch(`https://api.cloudflare.com/client/v4/zones/${zoneId}/purge_cache`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ files: [url] }),
  });

  if (response.ok) {
    console.log(`purged ${url}`);
    return;
  }

  throw new Error(`Cloudflare purge failed (${response.status}): ${await response.text()}`);
}

const [url] = process.argv.slice(2);
if (!url) {
  console.error("usage: purge-cloudflare.ts <url>");
  process.exit(1);
}

purgeFile(url).catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
