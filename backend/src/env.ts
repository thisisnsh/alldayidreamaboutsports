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
  // CDN hostname for the scores bucket (the §0 cache-only hostname), e.g.
  // https://scores.alldayidreamaboutsports.com. Used by the cache-health probe.
  get scoresDomain() {
    return required("SCORES_DOMAIN");
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
