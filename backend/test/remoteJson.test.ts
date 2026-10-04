import { describe, expect, it, vi } from "vitest";
import { readRemoteJson } from "../src/remoteJson.js";

describe("bounded upstream JSON", () => {
  it("accepts exactly the limit", async () => {
    await expect(readRemoteJson(new Response('{"ok":true}'), 11)).resolves.toEqual({ ok: true });
  });
  it("rejects a large advertised body without reading it", async () => {
    await expect(readRemoteJson(new Response("{}", { headers: { "content-length": "1000000000" } }), 11))
      .rejects.toThrow("byte limit");
  });
  it("cancels oversized chunked bodies even when the advertised size lies", async () => {
    const cancel = vi.fn();
    const body = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new Uint8Array(12)); }, cancel,
    });
    await expect(readRemoteJson(new Response(body, { headers: { "content-length": "1" } }), 11))
      .rejects.toThrow("byte limit");
    expect(cancel).toHaveBeenCalledOnce();
  });
  it("rejects malformed JSON", async () => {
    await expect(readRemoteJson(new Response("{broken"))).rejects.toThrow();
  });
});
