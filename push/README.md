# Isolated CDN → APNs service

This is a separate Node/Cloud Run service. It reads the same public, cached JSON as
the native app and sends ActivityKit updates and match notifications. It never
calls API-Football, reads R2 directly, writes scores, changes the Mac app's delivery
path, or invokes the existing backend. No existing backend code or deployment
workflow is imported or modified.

## Architecture and cost

Cloud Scheduler → dedicated Cloud Tasks queue → short Cloud Run requests → CDN →
dedicated Firestore database/outbox → APNs over HTTP/2.

- Once a minute the dispatcher reads cached schedules and checks for subscribers.
  Only followed/pinned matches in kickoff−5min through kickoff+5h get five-second
  polling tasks. Observed finished matches stop generating polls. Pending deliveries
  continue draining after polling stops. No polling requests sleep between ticks.
- Scores are fetched once per match, not once per subscriber. The public CDN remains
  the only score source, with no cache-busting parameters or provider credentials.
- The service scales to zero. Cloud Run's request-based free tier includes 2 million
  requests and 180,000 vCPU-seconds/month; Cloud Tasks includes its first million
  operations. These allowances are shared with other workloads in the billing
  account. A task creation and delivery both contribute to operations.
- The **named** Firestore database is billed; it does not get the default database's
  free quota. Subscriber fanout, outbox records, retries, logs, build/image storage,
  Scheduler, secrets and egress can add charges. Do not assume this is entirely free.
- At a small audience, reusing GCP's existing platform avoids an always-on server or
  a Worker-to-HTTP/2 gateway. Workers' `node:http2` is currently a stub. GCP is the
  chosen low-starting-cost implementation, not a claim to be cheapest at every scale.
- APNs delivery has no per-message Apple charge. At large audiences, add iOS 18+
  broadcast channels for Live Activities to reduce per-device fanout. This first
  version uses individual ActivityKit tokens and supports iOS/iPadOS 17+.

Sources: [Cloud Run](https://cloud.google.com/run/pricing),
[Cloud Tasks](https://cloud.google.com/tasks/pricing),
[Firestore](https://cloud.google.com/firestore/pricing),
[Workers HTTP/2 compatibility](https://developers.cloudflare.com/workers/runtime-apis/nodejs/),
[APNs broadcast](https://developer.apple.com/documentation/usernotifications/setting-up-broadcast-push-notifications/).

## Delivery behavior

- The first observation seeds a baseline. A gap over 90 seconds resynchronizes the
  current score without announcing old goals as new. The native timeline still
  shows historical events. A silent background wakeup is never used for scores.
- Full score/phase snapshots go to Live Activities. Score and phase changes and
  activity endings use priority 10; routine updates are coalesced to once a minute
  at priority 5. The iOS target declares frequent Live Activity updates, subject to
  the user's setting and Apple's delivery budget. There are no per-second clock pushes.
- Goal, disallowed goal, card, phase, substitution, shootout and recent VAR events
  generate distinct alert deliveries, filtered by team and event preferences.
  Each event has its own collapse ID, so distinct goals are not intentionally merged.
  Sports alerts use the normal interruption level, not Critical Alerts privileges.
- A Firestore transaction stores the new baseline and a durable fanout job together.
  Each bounded fanout page commits its delivery records and cursor together.
  The outbox records success, retries transient APNs/network failures with backoff,
  respects unregister/permission preferences, and removes rejected tokens without
  deleting a newer rotated token. Global leases and a serial queue prevent overlapping
  poll loops; version checks prevent acknowledging an update that replaced one in flight.
- Normal alerts/updates expire after two minutes; final Live Activity updates can
  retry for an hour, including pending final-score fanout jobs. Other stale fanout
  jobs are discarded after two minutes rather than delivering a burst of obsolete
  goals. Live Activity scores have a two-minute stale
  date. A final activity remains for up to an hour after its end update.
- APNs acceptance is not a device delivery receipt. A crash after APNs accepts a send
  but before the outbox records success can cause a retry/duplicate. This is bounded
  at-least-once delivery, not an exactly-once or zero-latency guarantee.
- Foreground iOS polling still supplies local alerts; foreground remote alert banners
  are suppressed to avoid double alerts. Background alerts are rendered by iOS itself.
  Turning off all mobile alerts and unpinning everything deletes the installation's
  subscription on the next successful sync. Otherwise it expires after 30 days without
  refresh. Delivery records expire approximately one day after their retry window;
  Firestore TTL deletion is asynchronous. Tokens and signing material are never logged.

## Build and checks (no credentials or simulators)

```sh
cd push
npm ci
npm run typecheck
npm test
npm run build
npm audit --audit-level=low
```

The checks cover delivery policy, CDN bounds, input/authentication boundaries,
lease/retry behavior, subscription changes, and token/version races. They mock
external dependencies; they do not prove deployed Firestore indexes/IAM or real
Apple delivery. No simulator is used.

## Open-source configuration and secrets

`secrets/AuthKey.p8.example` is a **nonfunctional placeholder**. An ignored
`secrets/AuthKey.p8` placeholder is also available in the current local workspace;
replace its entire contents with the real Apple signing key for local setup.
`.env.example` documents the environment contract; copy it to an ignored `.env` if
needed. Neither private keys nor real `.env` files belong in Git. `.dockerignore`
and `.gcloudignore` exclude them from images **and source uploads**.

For GitHub deployment, create separate `push-staging` and `push-production`
environments. Keep the original backend environments/secrets unchanged.

| GitHub environment secret | Value |
| --- | --- |
| `APNS_PRIVATE_KEY` | Entire real `.p8` PEM, including BEGIN/END lines |
| `APNS_KEY_ID` | Apple's 10-character signing-key ID |
| `PUSH_WORKLOAD_IDENTITY_PROVIDER` | Output of `infra/github.sh` |
| `PUSH_DEPLOY_SERVICE_ACCOUNT` | Output of `infra/github.sh` |

| GitHub environment variable | Value |
| --- | --- |
| `PUSH_GCP_PROJECT_ID` | `dreamaboutsports-staging` or `dreamaboutsports-prod` |
| `PUSH_GCP_REGION` | e.g. `us-central1` |
| `PUSH_FIREBASE_APP_ID` | Allowed Firebase Apple app ID, `1:…:ios:…` |
| `APNS_TEAM_ID` | `983LBM5U6B` for this app |
| `APNS_ENVIRONMENT` | `sandbox` for development provisioning; `production` for TestFlight/App Store |
| `PUSH_SCORES_ORIGIN` | One of the two explicitly allowed scores origins |

The manual `push-deploy` workflow checks/builds the service, uploads the key to
**only** the `sports-push-apns-key` Secret Manager secret, builds an image without
that key, then updates **only** `sports-cdn-push`. It uses GitHub OIDC/WIF, never a
long-lived Google service-account JSON key. Cloud Run accesses the signing key via
its own service identity. The workflow has no permission to read the key back.
It runs only from `main`, and defaults to dry-run. It does not resume a paused
scheduler. Forks must supply their own account/project/bundle IDs and adjust the
explicit project/CDN allowlists and native project configuration.

## Initial infrastructure setup (once per environment)

Use an administrator with gcloud and Firebase CLI credentials. These commands are
provided for review; no infrastructure has been deployed by this change.

1. In Apple Developer, enable Push Notifications and App Attest for the mobile
   app ID, refresh provisioning, and create an APNs token signing key permitted
   for the required environment. Preserve the existing Mac configuration.
2. In Firebase, use the Apple app configuration matching the mobile bundle ID
   and project. Register App Attest in App Check. The push service requires a
   verified token for that exact Firebase app; it has no unauthenticated or shared
   app-secret registration fallback. Do not disable validation for production.
3. Install the real key in Secret Manager, from the ignored file:

   ```sh
   gcloud secrets create sports-push-apns-key --replication-policy automatic --project PROJECT
   gcloud secrets versions add sports-push-apns-key --data-file push/secrets/AuthKey.p8 --project PROJECT
   bash push/infra/deploy.sh PROJECT us-central1 APPLE_KEY_ID FIREBASE_APP_ID sandbox
   ```

   The setup script fails before changes if that secret is absent. It prepares a
   named `sports-push` database with deny-all client rules, indexes and TTL policies;
   dedicated runtime/invoker identities; a separate queue, image repository,
   service and paused scheduler. The runtime gets database access conditioned on
   the named database, and only its own queue/key permissions. Existing score
   buckets, services, queues, scheduler jobs, rules and runtime accounts are not targeted.
   Initial source builds use the project's Cloud Build setup and need its usual
   source-build permissions. Subsequent GitHub builds run Docker on the runner.
4. Prepare the separate GitHub trust/identity, using numeric repository and owner
   IDs from GitHub (not reusable names alone):

   ```sh
   bash push/infra/github.sh PROJECT us-central1 OWNER/REPO REPOSITORY_ID OWNER_ID
   ```

   It creates its own WIF pool/provider and deploy identity. Trust is restricted to
   this repository/owner, `main`, this exact deployment workflow, and the two push
   environments. Permissions cover only the prepared push service, its runtime
   identity, its image repository and adding versions to its signing-key secret.
5. Fill the GitHub environment secrets/variables above. Wait for Firestore indexes
   to finish building. Run the manual workflow with `dry_run=true` initially.

**Staging CDN access:** the staging scores domain may be protected by Cloudflare
Access. This service deliberately has no Access bypass or origin credentials; a
403 fails closed. For sandbox-device testing against public real scores, set
`PUSH_SCORES_ORIGIN=https://scores.alldayidreamaboutsports.com` when running the
setup script and use that same origin in GitHub variables and the mobile build's
`APP_SCORES_BASE_URL`. This is a read-only public CDN request, not a provider call.

## Native app configuration

- Copy the correct Firebase plist to ignored
  `app/Resources/GoogleService-Info-iOS-Staging.plist` or
  `GoogleService-Info-iOS-Production.plist`. No private signing key belongs here.
- Create ignored `app/iOS/Push.local.xcconfig` with the generated Cloud Run URL:

  ```xcconfig
  APP_PUSH_BASE_URL = https:/$()/sports-cdn-push-YOUR_PROJECT_NUMBER.us-central1.run.app
  ```

  The `$()` is required to avoid treating `//` as an xcconfig comment. For automated
  builds, pass `APP_PUSH_BASE_URL` as an Xcode build setting instead. Use the correct
  endpoint for the build's APNs signing environment. A configured endpoint without
  its Firebase plist fails the build. An unconfigured contributor build still works
  with foreground polling and honestly reports background delivery as unconfigured.
- Regenerate with `xcodegen generate --spec app/project.yml`. Build the mobile scheme.
  Debug/DEV_BACKEND never registers fake fixtures or sends backend subscriptions.
  Use Staging with a development profile for sandbox APNs. TestFlight/App Store
  provisioning uses production APNs even for a staging build: point that build at a
  production-APNs service. The server environment is fixed, never client-selected.
- Both regular device tokens and per-Live-Activity tokens are registered and rotated.
  Installation credentials are generated on-device and stored in Keychain; the server
  stores their hash. Registration uses Firebase App Check/App Attest, and unchanged
  subscriptions only refresh hourly. Token/preference/pin changes sync promptly.

## Activate and roll back

After configuring a physical device, enable match notifications, follow a playing
team, and pin a live match. In dry-run, verify subscriptions, CDN reads and outbox
processing; the app must say that delivery is not active. Then run `push-deploy`
with `dry_run=false` and resume the **new** scheduler:

```sh
gcloud scheduler jobs resume sports-push-dispatch --location us-central1 --project PROJECT
```

Verify a real-device score update while locked, a goal alert, foreground duplicate
suppression, unpin, disabled alerts, token rotation, final-score ending and a failed
APNs attempt followed by retry. Confirm no fake IDs or credentials appear in logs.
High priority is a delivery request, not a guaranteed deadline. iOS notification,
Focus and frequent-update settings still apply. The website privacy-source change
must be published before distributing a mobile build that registers subscriptions.

Rollback only this feature: pause `sports-push-dispatch` and purge the `sports-push`
queue, or redeploy this service with `DRY_RUN=true`; remove the native push endpoint
for future builds if desired. The Mac app, CDN and existing backend keep operating.
The scheduler/queue are different resources from `live-scores` and must not be confused.
