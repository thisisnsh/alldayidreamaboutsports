import type { MatchState, Period } from "./types.js";

// Minimal raw-status → (status, period, running) mapping for synthetic matches.
// Mirrors the provider's derivation for the codes a test would use. Shared by the
// /internal/test-event endpoint and the tester/ fake publisher so both produce the
// same match shape from one raw-status table.
export function syntheticPhase(rawStatus: string, minute: number | null): {
  status: MatchState["status"]; period: Period; running: boolean;
} {
  switch (rawStatus) {
    case "1H": return { status: "LIVE", period: "FIRST", running: true };
    case "HT": return { status: "HALF_TIME", period: "HALF", running: false };
    case "2H": return { status: "LIVE", period: "SECOND", running: true };
    case "ET": return {
      status: "LIVE", period: (minute ?? 0) <= 105 ? "EXTRA_FIRST" : "EXTRA_SECOND", running: true,
    };
    case "BT": return {
      status: "LIVE",
      // ≤90 (or null) = ET setup break; 91..105 = between ET halves; >105 = pre-shootout.
      period: minute == null || minute <= 90 ? "BREAK" : minute <= 105 ? "EXTRA_BREAK" : "PENALTIES",
      running: false,
    };
    case "P": return { status: "LIVE", period: "PENALTIES", running: false };
    case "FT": case "AET": case "PEN": return { status: "FINISHED", period: "FINISHED", running: false };
    case "NS": case "TBD": return { status: "SCHEDULED", period: "PRE", running: false };
    default: return { status: "OTHER", period: "OTHER", running: false };
  }
}
