import { z } from "zod";

const origin = z.string().url().refine(value => {
  const u = new URL(value);
  return u.protocol === "https:" && u.origin === value && !u.username && !u.password;
});
const schema = z.object({
  GCP_PROJECT_ID: z.string().min(1),
  SERVICE_URL: origin,
  SCORES_ORIGIN: origin.refine(value => [
    "https://scores.alldayidreamaboutsports.com",
    "https://scores-staging.alldayidreamaboutsports.com",
  ].includes(value)),
  TASKS_LOCATION: z.string().default("us-central1"),
  TASKS_QUEUE: z.string().default("sports-push"),
  INVOKER_EMAIL: z.string().email(),
  FIRESTORE_DATABASE: z.string().default("sports-push"),
  FIREBASE_APP_IDS: z.string().min(1),
  APNS_TEAM_ID: z.string().regex(/^[A-Z0-9]{10}$/),
  APNS_KEY_ID: z.string().regex(/^[A-Z0-9]{10}$/),
  APNS_PRIVATE_KEY: z.string().min(50),
  APNS_BUNDLE_ID: z.string().default("com.thisisnsh.alldaysports"),
  APNS_ENVIRONMENT: z.enum(["sandbox", "production"]),
  DRY_RUN: z.enum(["true", "false"]).default("true"),
  POLL_SECONDS: z.coerce.number().refine(n => [5, 10, 15, 30].includes(n)).default(5),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
});
export type Config = z.infer<typeof schema>;
export const readConfig = (input: NodeJS.ProcessEnv): Config => schema.parse(input);
