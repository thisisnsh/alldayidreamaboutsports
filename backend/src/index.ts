import { CatalogService } from "./catalog.js";
import { CelebrationAggregator } from "./celebrations.js";
import { env } from "./env.js";
import { Fcm } from "./fcm.js";
import { Poller } from "./poller.js";
import { ApiFootballProvider } from "./providers/apiFootball.js";
import { R2 } from "./r2.js";
import { buildApp } from "./routes.js";
import { Store } from "./store.js";

const store = new Store();
const fcm = new Fcm();
const r2 = new R2();
const provider = new ApiFootballProvider(env.apiFootballKey, env.leagueId, env.season);
const celebrations = new CelebrationAggregator(store);
const poller = new Poller(provider, store, fcm, r2);
const catalog = new CatalogService(provider, r2);

celebrations.start();

const app = buildApp({ store, fcm, poller, catalog, celebrations });
const server = app.listen(env.port, () => {
  console.log(`alldayidreamaboutsports-backend listening on :${env.port}`);
});

process.on("SIGTERM", async () => {
  await celebrations.stop(); // flush buffered taps before Cloud Run kills us
  server.close(() => process.exit(0));
});
