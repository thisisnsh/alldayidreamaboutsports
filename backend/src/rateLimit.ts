export class FixedWindowRateLimiter {
  private readonly requests = new Map<string, { windowStartedAt: number; count: number }>();
  private callsUntilSweep = 1_000;

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
    private readonly now: () => number = Date.now,
  ) {}

  allow(key: string): boolean {
    const now = this.now();
    if (--this.callsUntilSweep === 0) {
      for (const [existingKey, request] of this.requests) {
        if (now - request.windowStartedAt >= this.windowMs) this.requests.delete(existingKey);
      }
      this.callsUntilSweep = 1_000;
    }
    const current = this.requests.get(key);
    if (!current || now - current.windowStartedAt >= this.windowMs) {
      this.requests.set(key, { windowStartedAt: now, count: 1 });
      return true;
    }
    if (current.count >= this.limit) return false;
    current.count++;
    return true;
  }
}
