import { CloudTasksClient } from "@google-cloud/tasks";
import { CatalogService } from "./catalog.js";
import { env, validateEnvironment } from "./env.js";
import { Poller } from "./poller.js";
import { ApiFootballProvider } from "./providers/apiFootball.js";
import { R2, R2MatchStateStore } from "./r2.js";
import { buildApp } from "./routes.js";
import { ScheduleService } from "./schedule.js";
import { Dispatcher, MatchWindow } from "./tasks.js";
import { log } from "./log.js";
import { validateServiceAuthentication } from "./auth.js";

validateServiceAuthentication();
validateEnvironment();

const r2 = new R2();
const provider = new ApiFootballProvider(env.apiFootballKey);
const state = new R2MatchStateStore();
const poller = new Poller(provider, state, r2);
const window = new MatchWindow(r2);
const dispatcher = new Dispatcher(new CloudTasksClient(), window);
const catalog = new CatalogService(provider, r2);
const schedule = new ScheduleService(provider, r2);

const app = buildApp({ poller, dispatcher, window, catalog, schedule, r2 });
const server = app.listen(env.port, () => {
  log.info("backend_listening", { port: env.port });
});

process.on("SIGTERM", () => {
  server.close(() => process.exit(0));
});
