import { describe, expect, it, vi } from "vitest";
import { probeCacheHealth } from "../src/routes.js";

function response(cacheStatus: string | null, status = 200) {
  return {
    status,
    headers: { get: (h: string) => (h.toLowerCase() === "cf-cache-status" ? cacheStatus : null) },
    arrayBuffer: () => Promise.resolve(new ArrayBuffer(0)),
  };
}

describe("probeCacheHealth (cf-cache-status probe)", () => {
  it("probes catalog.json + each live match file on the scores hostname", async () => {
    const fetchMock = vi.fn().mockResolvedValue(response("HIT"));
    const result = await probeCacheHealth("https://scores.example.com", [101, 202], fetchMock as never);

    expect(result.ok).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      "https://scores.example.com/catalog.json",
      expect.objectContaining({ method: "GET", signal: expect.any(AbortSignal), redirect: "error" }),
    );
    expect(fetchMock).toHaveBeenCalledWith(
      "https://scores.example.com/matches/101.json",
      expect.objectContaining({ method: "GET", signal: expect.any(AbortSignal), redirect: "error" }),
    );
    expect(fetchMock).toHaveBeenCalledWith(
      "https://scores.example.com/matches/202.json",
      expect.objectContaining({ method: "GET", signal: expect.any(AbortSignal), redirect: "error" }),
    );
    expect(result.probes.map((p) => p.cacheStatus)).toEqual(["HIT", "HIT", "HIT"]);
  });

  it("flags an edge-cached HTTP failure even when cf-cache-status is HIT", async () => {
    const fetchMock = vi.fn().mockResolvedValue(response("HIT", 404));
    const result = await probeCacheHealth("https://scores.example.com", [], fetchMock as never);
    expect(result.ok).toBe(false);
    expect(result.unhealthy[0]).toMatchObject({ key: "catalog.json", httpStatus: 404, cacheStatus: "HIT" });
  });

  it("treats HIT/REVALIDATED/STALE/UPDATING as healthy", async () => {
    const statuses = ["HIT", "REVALIDATED", "STALE", "UPDATING"];
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response(statuses[0]!))
      .mockResolvedValueOnce(response(statuses[1]!))
      .mockResolvedValueOnce(response(statuses[2]!))
      .mockResolvedValueOnce(response(statuses[3]!));
    const result = await probeCacheHealth("https://scores.example.com", [1, 2, 3], fetchMock as never);
    expect(result.ok).toBe(true);
    expect(result.unhealthy).toEqual([]);
  });

  it("retries a cold MISS/EXPIRED once and accepts the warmed HIT", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response("EXPIRED"))
      .mockResolvedValueOnce(response("HIT"));

    const result = await probeCacheHealth("https://scores.example.com", [], fetchMock as never);

    expect(result.ok).toBe(true);
    expect(result.probes[0]).toMatchObject({
      key: "catalog.json",
      cacheStatus: "HIT",
      attempts: ["EXPIRED", "HIT"],
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("flags sustained MISS/BYPASS/DYNAMIC as unhealthy (users would hit R2)", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response("HIT")) // catalog ok
      .mockResolvedValueOnce(response("BYPASS")) // matches/1 — header-less object?
      .mockResolvedValueOnce(response("DYNAMIC")); // matches/2 — rule missing?
    const result = await probeCacheHealth("https://scores.example.com", [1, 2], fetchMock as never);

    expect(result.ok).toBe(false);
    expect(result.unhealthy.map((p) => p.key)).toEqual(["matches/1.json", "matches/2.json"]);
  });

  it("captures a fetch failure as an ERROR probe (not a thrown rejection)", async () => {
    const fetchMock = vi.fn().mockRejectedValue(new Error("ENOTFOUND"));
    const result = await probeCacheHealth("https://scores.example.com/", [], fetchMock as never);

    expect(result.ok).toBe(false);
    expect(result.probes[0]).toMatchObject({ key: "catalog.json", cacheStatus: "ERROR", error: "ENOTFOUND" });
  });

  it("trims a trailing slash on the scores domain", async () => {
    const fetchMock = vi.fn().mockResolvedValue(response("HIT"));
    await probeCacheHealth("https://scores.example.com/", [], fetchMock as never);
    expect(fetchMock).toHaveBeenCalledWith(
      "https://scores.example.com/catalog.json",
      expect.anything(),
    );
  });

  it("accepts a bare scores hostname from Cloud Run env", async () => {
    const fetchMock = vi.fn().mockResolvedValue(response("HIT"));
    await probeCacheHealth("scores.example.com", [], fetchMock as never);
    expect(fetchMock).toHaveBeenCalledWith(
      "https://scores.example.com/catalog.json",
      expect.objectContaining({ method: "GET", signal: expect.any(AbortSignal), redirect: "error" }),
    );
  });
});
