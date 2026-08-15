import { beforeAll, describe, expect, it, vi } from "vitest";

beforeAll(() => {
  process.env.GCP_PROJECT_ID = "test-project";
  process.env.SERVICE_URL = "https://svc.run.app";
  process.env.TASKS_QUEUE = "live-scores";
  process.env.TASKS_LOCATION = "us-central1";
  process.env.SCHEDULER_SA_EMAIL = "sports-scheduler@test-project.iam.gserviceaccount.com";
});

/** A window that is always open, for the tests that are not about the gate. */
const openWindow = { isOpen: async () => true } as never;

describe("Dispatcher", () => {
  it("enqueues N tasks at fixed second offsets targeting /internal/fetch with OIDC", async () => {
    const { Dispatcher } = await import("../src/tasks.js");
    const createTask = vi.fn().mockResolvedValue([{}]);
    const client = {
      queuePath: (p: string, l: string, q: string) => `projects/${p}/locations/${l}/queues/${q}`,
      createTask,
    };
    const dispatcher = new Dispatcher(client, openWindow, 12, 5);

    const result = await dispatcher.dispatch(new Date("2026-06-14T18:30:00Z").getTime());

    expect(result).toEqual({ enqueued: 12 });
    expect(createTask).toHaveBeenCalledTimes(12);

    const base = Math.floor(new Date("2026-06-14T18:30:00Z").getTime() / 1000);
    const tasks = createTask.mock.calls.map(([req]) => req.task);
    expect(tasks.map((t) => t.scheduleTime.seconds)).toEqual(
      Array.from({ length: 12 }, (_, i) => base + i * 5),
    );

    const first = tasks[0];
    expect(first.httpRequest.httpMethod).toBe("POST");
    expect(first.httpRequest.url).toBe("https://svc.run.app/internal/fetch");
    expect(first.httpRequest.oidcToken).toEqual({
      serviceAccountEmail: "sports-scheduler@test-project.iam.gserviceaccount.com",
      audience: "https://svc.run.app",
    });
    expect(new Set(tasks.map((t) => t.name)).size).toBe(12); // unique per slot
  });

  it("swallows ALREADY_EXISTS so a double dispatch is a no-op", async () => {
    const { Dispatcher } = await import("../src/tasks.js");
    const createTask = vi.fn().mockRejectedValue({ code: 6 });
    const client = {
      queuePath: () => "projects/p/locations/l/queues/q",
      createTask,
    };
    const dispatcher = new Dispatcher(client, openWindow, 3, 5);

    await expect(dispatcher.dispatch()).resolves.toEqual({ enqueued: 3 });
  });
});

describe("Dispatcher match-window gate", () => {
  const KICKOFF = "2026-08-15T19:00:00Z";

  async function dispatcherFor(fixturesByDate: Record<string, unknown>) {
    const { Dispatcher, MatchWindow } = await import("../src/tasks.js");
    const createTask = vi.fn().mockResolvedValue([{}]);
    const getJson = vi.fn(async (key: string) => fixturesByDate[key] ?? null);
    const client = {
      queuePath: (p: string, l: string, q: string) => `projects/${p}/locations/${l}/queues/${q}`,
      createTask,
    };
    const window = new MatchWindow({ getJson } as never);
    return { dispatcher: new Dispatcher(client, window, 12, 5), createTask, getJson };
  }

  const dayWith = (...kickoffs: string[]) => ({
    matches: kickoffs.map((kickoffISO, i) => ({ fixtureId: i, kickoffISO })),
  });

  it("enqueues inside the window", async () => {
    const { dispatcher, createTask } = await dispatcherFor({
      "fixtures-2026-08-15.json": dayWith(KICKOFF),
    });

    // Mid-match.
    const result = await dispatcher.dispatch(Date.parse("2026-08-15T20:00:00Z"));

    expect(result).toEqual({ enqueued: 12 });
    expect(createTask).toHaveBeenCalledTimes(12);
  });

  it("opens 30 minutes before kickoff and closes four hours after it", async () => {
    const at = async (iso: string) => {
      const { dispatcher } = await dispatcherFor({ "fixtures-2026-08-15.json": dayWith(KICKOFF) });
      return (await dispatcher.dispatch(Date.parse(iso))).enqueued;
    };

    expect(await at("2026-08-15T18:29:00Z")).toBe(0); // 31min out
    expect(await at("2026-08-15T18:31:00Z")).toBe(12); // 29min out
    expect(await at("2026-08-15T22:59:00Z")).toBe(12); // kickoff + 3h59
    expect(await at("2026-08-15T23:01:00Z")).toBe(0); // kickoff + 4h01
  });

  it("enqueues nothing outside the window — no tasks, not no-op tasks", async () => {
    const { dispatcher, createTask } = await dispatcherFor({
      "fixtures-2026-08-15.json": dayWith(KICKOFF),
    });

    const result = await dispatcher.dispatch(Date.parse("2026-08-15T06:00:00Z"));

    expect(result).toEqual({ enqueued: 0 });
    expect(createTask).not.toHaveBeenCalled();
  });

  it("stays shut overnight between a late Saturday match and an early Sunday one", async () => {
    // The gate is the union of per-match windows, not one min→max envelope: a
    // single envelope over both days would hold it open all night.
    const { dispatcher, createTask } = await dispatcherFor({
      "fixtures-2026-08-15.json": dayWith("2026-08-15T11:30:00Z", "2026-08-15T19:00:00Z"),
      "fixtures-2026-08-16.json": dayWith("2026-08-16T14:00:00Z"),
    });

    // 04:00 Sunday: four hours past Saturday's last match, ten before Sunday's.
    const result = await dispatcher.dispatch(Date.parse("2026-08-16T04:00:00Z"));

    expect(result).toEqual({ enqueued: 0 });
    expect(createTask).not.toHaveBeenCalled();
  });

  it("reads yesterday's file too, so a match past UTC midnight keeps polling", async () => {
    const { dispatcher } = await dispatcherFor({
      "fixtures-2026-08-15.json": dayWith("2026-08-15T21:00:00Z"),
      // Nothing on the 16th at all.
    });

    // 00:30 on the 16th: 3.5h after a kickoff filed under the 15th.
    const result = await dispatcher.dispatch(Date.parse("2026-08-16T00:30:00Z"));

    expect(result).toEqual({ enqueued: 12 });
  });

  it("opens no window when the schedule file is missing, rather than throwing", async () => {
    const { dispatcher, createTask } = await dispatcherFor({}); // getJson -> null

    await expect(dispatcher.dispatch(Date.parse("2026-08-15T20:00:00Z")))
      .resolves.toEqual({ enqueued: 0 });
    expect(createTask).not.toHaveBeenCalled();
  });

  it("fails closed when the R2 read errors, rather than polling blind", async () => {
    const { Dispatcher, MatchWindow } = await import("../src/tasks.js");
    const createTask = vi.fn();
    const client = { queuePath: () => "q", createTask };
    const window = new MatchWindow({
      getJson: vi.fn().mockRejectedValue(new Error("R2 down")),
    } as never);
    const dispatcher = new Dispatcher(client, window, 12, 5);

    await expect(dispatcher.dispatch(Date.parse("2026-08-15T20:00:00Z")))
      .resolves.toEqual({ enqueued: 0 });
    expect(createTask).not.toHaveBeenCalled();
  });

  it("caches the schedule read per date — one R2 GET per day, not per minute", async () => {
    const { dispatcher, getJson } = await dispatcherFor({
      "fixtures-2026-08-15.json": dayWith(KICKOFF),
    });

    await dispatcher.dispatch(Date.parse("2026-08-15T20:00:00Z"));
    await dispatcher.dispatch(Date.parse("2026-08-15T20:01:00Z"));
    await dispatcher.dispatch(Date.parse("2026-08-15T20:02:00Z"));

    // Two dates (today + yesterday), read once each.
    expect(getJson).toHaveBeenCalledTimes(2);
  });
});
