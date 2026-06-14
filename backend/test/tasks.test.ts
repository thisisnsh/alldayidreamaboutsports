import { beforeAll, describe, expect, it, vi } from "vitest";

beforeAll(() => {
  process.env.GCP_PROJECT_ID = "test-project";
  process.env.SERVICE_URL = "https://svc.run.app";
  process.env.TASKS_QUEUE = "live-scores";
  process.env.TASKS_LOCATION = "us-central1";
  process.env.SCHEDULER_SA_EMAIL = "sports-scheduler@test-project.iam.gserviceaccount.com";
});

describe("Dispatcher", () => {
  it("enqueues N tasks at fixed second offsets targeting /internal/fetch with OIDC", async () => {
    const { Dispatcher } = await import("../src/tasks.js");
    const createTask = vi.fn().mockResolvedValue([{}]);
    const client = {
      queuePath: (p: string, l: string, q: string) => `projects/${p}/locations/${l}/queues/${q}`,
      createTask,
    };
    const dispatcher = new Dispatcher(client, 12, 5);

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
    const dispatcher = new Dispatcher(client, 3, 5);

    await expect(dispatcher.dispatch()).resolves.toEqual({ enqueued: 3 });
  });
});
