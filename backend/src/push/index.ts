import { OAuth2Client } from "google-auth-library";
import { initializeApp } from "firebase-admin/app";
import { getAppCheck } from "firebase-admin/app-check";
import { getFirestore } from "firebase-admin/firestore";
import { readConfig } from "./config.js";
import { Store } from "./store.js";
import { CDN } from "./cdn.js";
import { APNs } from "./apns.js";
import { Worker } from "./worker.js";
import { createApp } from "./routes.js";

const config = readConfig(process.env);
const firebase = initializeApp({ projectId: config.GCP_PROJECT_ID });
const store = new Store(getFirestore(firebase, config.FIRESTORE_DATABASE));
const sender = new APNs(config);
const worker = new Worker(config, new CDN(config.SCORES_ORIGIN), store, sender);
const oidc = new OAuth2Client();
const app = createApp(config, {
  store, worker,
  verifyOidc: async token => (await oidc.verifyIdToken({ idToken: token, audience: config.SERVICE_URL })).getPayload() ?? {},
  verifyAppCheck: token => getAppCheck(firebase).verifyToken(token),
});
const server = app.listen(config.PORT);
process.on("SIGTERM", () => { server.close(); sender.close(); });
