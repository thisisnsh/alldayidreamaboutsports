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
      scoresBucket: process.env.R2_BUCKET_SCORES ?? "alldayidreamaboutsports-scores",
    };
  },
  get schedulerServiceAccount() {
    return (
      process.env.SCHEDULER_SA_EMAIL ??
      `sports-scheduler@${required("GCP_PROJECT_ID")}.iam.gserviceaccount.com`
    );
  },
  leagueId: Number(process.env.LEAGUE_ID ?? 1), // World Cup
  season: Number(process.env.SEASON ?? 2026),
  port: Number(process.env.PORT ?? 8080),
};
