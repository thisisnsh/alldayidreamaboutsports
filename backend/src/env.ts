function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var ${name}`);
  return v;
}

export const env = {
  get projectId() {
    return required("GCP_PROJECT_ID");
  },
  get apiFootballKey() {
    return required("API_FOOTBALL_KEY");
  },
  get r2() {
    return {
      endpoint: required("R2_ENDPOINT"),
      accessKeyId: required("R2_ACCESS_KEY_ID"),
      secretAccessKey: required("R2_SECRET_ACCESS_KEY"),
      scoresBucket: required("R2_BUCKET_SCORES"),
    };
  },
  get schedulerServiceAccount() {
    return (
      process.env.SCHEDULER_SA_EMAIL ??
      `sports-scheduler@${required("GCP_PROJECT_ID")}.iam.gserviceaccount.com`
    );
  },
  get serviceUrl() {
    const value = required("SERVICE_URL");
    const url = new URL(value);
    if (url.protocol !== "https:" || url.origin !== value) {
      throw new Error("SERVICE_URL must be an HTTPS origin without a path or trailing slash");
    }
    return value; // Cloud Run audience and Cloud Tasks target
  },
  get deployServiceAccount() {
    return process.env.DEPLOY_SA_EMAIL ?? `sports-deploy@${required("GCP_PROJECT_ID")}.iam.gserviceaccount.com`;
  },
  // CDN hostname for the scores bucket, e.g.
  // https://scores.alldayidreamaboutsports.com. Used by the cache-health probe.
  get scoresDomain() {
    const value = required("SCORES_DOMAIN");
    const url = new URL(value);
    if (url.protocol !== "https:" || url.origin !== value) {
      throw new Error("SCORES_DOMAIN must be an HTTPS origin without a path or trailing slash");
    }
    return value;
  },
  tasksQueue: process.env.TASKS_QUEUE ?? "live-scores",
  tasksLocation: process.env.TASKS_LOCATION ?? "us-central1",
  // The leagues the poller and the schedule sync fetch, in kickoff-density
  // order. Seasons are NOT configured here — they come per-league from
  // catalog.json, so the August season rollover needs no deploy.
  leagueIds: (process.env.LEAGUE_IDS ?? "39,140,135,78,61")
    .split(",")
    .map((id) => Number(id.trim()))
    .filter((id) => Number.isFinite(id) && id > 0),
  port: Number(process.env.PORT ?? 8080),
};

/** Fail before listening, rather than on the first scheduled request. */
export function validateEnvironment(): void {
  void env.projectId;
  void env.apiFootballKey;
  void env.serviceUrl;
  void env.scoresDomain;
  const r2 = env.r2;
  const endpoint = new URL(r2.endpoint);
  if (endpoint.protocol !== "https:" || endpoint.origin !== r2.endpoint) {
    throw new Error("R2_ENDPOINT must be an HTTPS origin");
  }
  if (!Number.isInteger(env.port) || env.port < 1 || env.port > 65535) throw new Error("Invalid PORT");
  if (!env.leagueIds.length) throw new Error("LEAGUE_IDS must contain a positive league ID");
}
