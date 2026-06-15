import { CloudTasksClient } from "@google-cloud/tasks";
import { env } from "./env.js";
import { log } from "./log.js";

const GRPC_ALREADY_EXISTS = 6;

// Minimal surface we use, so tests can inject a fake without the full client.
export interface TasksClient {
  queuePath(project: string, location: string, queue: string): string;
  createTask(request: unknown): Promise<unknown>;
}

/**
 * Fans a minute out into N short fetches. Cloud Scheduler is minute-granular, so
 * once a minute it hits /internal/dispatch, which enqueues N Cloud Tasks spaced
 * `stepSeconds` apart via each task's precise scheduleTime. Each task then hits
 * /internal/fetch (a single, fast read) — so we get sub-minute cadence without
 * any request sleeping and pinning the CPU.
 */
export class Dispatcher {
  constructor(
    private readonly client: TasksClient = new CloudTasksClient(),
    private readonly count = 12,
    private readonly stepSeconds = 5,
  ) {}

  async dispatch(now = Date.now()): Promise<{ enqueued: number }> {
    const parent = this.client.queuePath(env.projectId, env.tasksLocation, env.tasksQueue);
    const url = `${env.serviceUrl}/internal/fetch`;
    const startSeconds = Math.floor(now / 1000);
    const minuteBucket = Math.floor(now / 60_000);
    log.info("dispatch_start", {
      count: this.count, stepSeconds: this.stepSeconds, minuteBucket, url,
    });

    await Promise.all(
      Array.from({ length: this.count }, (_, i) =>
        Promise.resolve(
          this.client.createTask({
            parent,
            task: {
              // Deterministic name → Cloud Tasks dedups for ~1h, so a double
              // dispatch in the same minute is a no-op.
              name: `${parent}/tasks/fetch-${minuteBucket}-${i}`,
              scheduleTime: { seconds: startSeconds + i * this.stepSeconds },
              httpRequest: {
                httpMethod: "POST",
                url,
                oidcToken: {
                  serviceAccountEmail: env.schedulerServiceAccount,
                  audience: env.serviceUrl,
                },
              },
            },
          }),
        ).catch((err: { code?: number }) => {
          if (err?.code !== GRPC_ALREADY_EXISTS) throw err;
        }),
      ),
    );

    log.info("dispatch_complete", { enqueued: this.count, minuteBucket });
    return { enqueued: this.count };
  }
}
