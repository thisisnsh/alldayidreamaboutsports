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
  get sessionJwtSecret() {
    return required("SESSION_JWT_SECRET");
  },
  get googleOauthClientId() {
    return required("GOOGLE_OAUTH_CLIENT_ID");
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
    return required("SERVICE_URL"); // public Cloud Run URL; Cloud Tasks targets it
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
  // Client reporter probability + server multiply-back factor. MUST equal the
  // RC `celebration_sample_percent`. 1.0 = everyone reports → exact counts.
  celebrationSampleRate: Number(process.env.CELEBRATION_SAMPLE_RATE ?? 1),
  // Probability that a flush also READS the shards and republishes the totals
  // file. The shard increment always runs, so no tap is ever lost; this only
  // thins the read half, which is what costs Firestore money at scale. Across
  // ~30 Cloud Run instances flushing every 1.5s, 0.1 still republishes about
  // twice a second — faster than the 5s edge TTL can serve.
  celebrationPublishRate: Number(process.env.CELEBRATION_PUBLISH_RATE ?? 0.1),
};
