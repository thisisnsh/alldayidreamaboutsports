import { matchSchema, type Match } from "./model.js";
import { z } from "zod";

/** CDN-only reads. No R2 SDK, bucket credentials, provider key, redirects, or cache busting. */
export class CDN {
  private schedules = new Map<string, { at: number; matches: Match[] }>();
  constructor(private origin: string, private fetcher: typeof fetch = fetch) {}

  private async json(path: string): Promise<unknown | null> {
    const response = await this.fetcher(`${this.origin}/${path}`, {
      redirect: "error", signal: AbortSignal.timeout(8000),
    });
    if (response.status === 404) { await response.body?.cancel(); return null; }
    if (!response.ok) { await response.body?.cancel(); throw new Error(`CDN HTTP ${response.status}`); }
    if (Number(response.headers.get("content-length")) > 2_000_000) {
      await response.body?.cancel(); throw new Error("CDN payload too large");
    }
    if (!response.body) throw new Error("Empty CDN response");
    const reader = response.body.getReader(); const chunks: Uint8Array[] = []; let size = 0;
    try {
      while (true) {
        const { value, done } = await reader.read(); if (done) break;
        size += value.length; if (size > 2_000_000) throw new Error("CDN payload too large");
        chunks.push(value);
      }
      return JSON.parse(Buffer.concat(chunks).toString("utf8"));
    } finally { await reader.cancel().catch(() => undefined); reader.releaseLock(); }
  }

  async match(id: number): Promise<Match | null> {
    if (!Number.isSafeInteger(id) || id <= 0) throw new Error("Invalid fixture id");
    const raw = await this.json(`matches/${id}.json`);
    if (raw == null) return null;
    const m = matchSchema.parse(raw);
    if (m.fixtureId !== id) throw new Error("Wrong fixture returned by CDN");
    return m;
  }

  async window(now: number): Promise<Match[]> {
    const dates = [-1, 0, 1].map(offset => new Date(now + offset * 86_400_000).toISOString().slice(0, 10));
    for (const key of this.schedules.keys()) if (!dates.includes(key)) this.schedules.delete(key);
    const rows = await Promise.all(dates.map(async date => {
      const old = this.schedules.get(date);
      if (old && now - old.at < 600_000) return old.matches;
      const raw = await this.json(`fixtures-${date}.json`);
      if (raw == null) return [];
      const matches = z.object({ matches: z.array(matchSchema).max(512) }).parse(raw).matches;
      this.schedules.set(date, { at: now, matches }); return matches;
    }));
    return [...new Map(rows.flat().filter(m => {
      const kickoff = Date.parse(m.kickoffISO);
      return now >= kickoff - 300_000 && now <= kickoff + 5 * 3_600_000;
    }).map(m => [m.fixtureId, m])).values()];
  }
}
