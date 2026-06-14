import { describe, expect, it } from "vitest";
import { FixedWindowRateLimiter } from "../src/rateLimit.js";

describe("FixedWindowRateLimiter", () => {
  it("limits each key independently", () => {
    const limiter = new FixedWindowRateLimiter(2, 60_000, () => 0);

    expect(limiter.allow("user-1")).toBe(true);
    expect(limiter.allow("user-1")).toBe(true);
    expect(limiter.allow("user-1")).toBe(false);
    expect(limiter.allow("user-2")).toBe(true);
  });

  it("allows requests again after the window resets", () => {
    let now = 0;
    const limiter = new FixedWindowRateLimiter(1, 60_000, () => now);

    expect(limiter.allow("user-1")).toBe(true);
    expect(limiter.allow("user-1")).toBe(false);
    now = 60_000;
    expect(limiter.allow("user-1")).toBe(true);
  });
});
