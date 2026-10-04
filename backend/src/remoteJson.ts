/** Bound decoded response bytes, including chunked/compressed upstream bodies. */
export async function readRemoteJson(response: Response, maxBytes = 8 * 1024 * 1024): Promise<unknown> {
  if (Number(response.headers.get("content-length")) > maxBytes) {
    await response.body?.cancel();
    throw new Error("Upstream response exceeds byte limit");
  }
  if (!response.body) throw new Error("Upstream response has no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) throw new Error("Upstream response exceeds byte limit");
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks, size).toString("utf8")) as unknown;
  } finally {
    await reader.cancel().catch(() => undefined);
    reader.releaseLock();
  }
}
