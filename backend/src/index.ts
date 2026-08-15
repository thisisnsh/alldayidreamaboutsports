import { CatalogService } from "./catalog.js";
import { CelebrationAggregator } from "./celebrations.js";
import { env } from "./env.js";
import { Poller } from "./poller.js";
import { ApiFootballProvider } from "./providers/apiFootball.js";
import { R2, R2MatchStateStore } from "./r2.js";
import { buildApp } from "./routes.js";
import { ScheduleService } from "./schedule.js";
import { Store } from "./store.js";
import { Dispatcher } from "./tasks.js";
import { log } from "./log.js";

const store = new Store();
const r2 = new R2();
const provider = new ApiFootballProvider(env.apiFootballKey);
const state = new R2MatchStateStore();
const celebrations = new CelebrationAggregator(store, r2);
const poller = new Poller(provider, state, r2);
const dispatcher = new Dispatcher();
const catalog = new CatalogService(provider, r2);
const schedule = new ScheduleService(provider, r2);

celebrations.start();

const app = buildApp({ store, poller, dispatcher, catalog, schedule, celebrations, r2 });
const server = app.listen(env.port, () => {
  log.info("backend_listening", { port: env.port });
});

process.on("SIGTERM", async () => {
  await celebrations.stop(); // flush buffered taps before Cloud Run kills us
  server.close(() => process.exit(0));
});
