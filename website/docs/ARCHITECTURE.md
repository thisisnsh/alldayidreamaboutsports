# Architecture

How [All Day I Dream About Sports](https://alldayidreamaboutsports.com) delivers
live football to a Mac menu bar.

The app and backend are closed source; this is a description of the system, not
a blueprint for running it. Hostnames, routes, credentials, exact limits and
provider quotas are deliberately left out.

---

## The constraint

A live-score app looks like a push problem. Something happens in Madrid, and a
few hundred thousand menu bars need to know within seconds.

Push is the expensive answer. Per-user delivery means per-user infrastructure:
device tokens, fan-out workers, retry queues, a bill that grows with every
install even though the *information* is identical for everyone. A goal is not
personal data. It's one fact, and everybody wants the same copy of it.

So the system doesn't push anything.

## The shape

```
                        ┌── enqueues work only inside a live match window
                        ▼
  Football data ──▶ Cloud Run service ──▶ object storage ──▶ CDN edge
   provider            │         ▲                             │
                       │         │  sign-in · celebrate         │  poll
                       ▼         │                              │
                   Firestore     └────────── macOS apps ◀───────┘
```

One deployable with two personalities:

**The public API** handles sign-in, the celebration counter and account
deletion. It is the only thing users talk to directly, and it is the only thing
whose load scales with how popular the app gets.

**The internal poller** is invoked on a schedule, never by a user. A scheduler
job wakes it each minute; that invocation fans out into a series of short tasks
spaced a few seconds apart, so the polling cadence lives in the queue's
scheduling rather than in a process that sleeps. Nothing is billed for waiting.

Each task reads a rolling multi-day fixture window from the data provider — one
call per league — diffs the result against the last published state, and writes
only what changed.

## Publishing a goal

State lands in object storage as small JSON files behind a CDN with a short edge
TTL. Every client polls the same objects. There is no user identity involved in
reading a score, so there is nothing to personalize, authenticate or fan out.

What that buys:

| Event | Backend cost |
|---|---|
| A goal is scored | one write |
| Ten people are watching | one write |
| Ten million people are watching | one write |

Reads are served by the edge. The interesting failure mode isn't traffic — it's
the *expiry stampede*: every client's cached copy goes stale at the same instant
and they all miss at once. Tiered caching solves it by funnelling edge misses
through a small number of upper-tier data centres, so the origin sees a trickle
instead of a wall. Without it the origin read rate is more than an order of
magnitude higher for the same audience.

Two details make this reliable rather than merely cheap:

- **Comparison state is private.** The state the differ reads is kept separately
  from the state clients read, and updates use conditional writes so two
  overlapping ticks can't publish a stale score over a fresh one.
- **A published write is the delivery.** There's no second step that can fail
  halfway. If the object changed, everyone gets it on their next poll.

A separate scheduled probe watches cache-hit headers continuously and alerts if
users start reaching the origin — a falling hit ratio is treated as a sev-1,
because it's the leading indicator of the bill and the latency both going wrong
at once.

## The match-window gate

Five leagues are live roughly 38 hours in a week, not 168. Polling around the
clock would burn through the data provider's daily quota and spend most of that
budget confirming that nothing is happening on a Wednesday morning.

So the dispatcher gates itself. It reads a periodically refreshed fixture
schedule and, unless some match is inside its live window — from shortly before
kickoff to a few hours after — it enqueues nothing at all. No provider calls, no
compute, no writes.

That gate is the difference between a plan that fits and one that doesn't, which
is why it's guarded as an invariant rather than treated as an optimisation. A
schedule sync runs on its own slower cadence precisely so the gate always has
something to read while the poller sleeps, and a daily catalog sync keeps league,
season and team metadata (including badge art) current — seasons resolve from
that catalog rather than from configuration, so the August rollover needs no
deploy.

## Celebrations

This is the one feature that genuinely scales with users: when your team scores,
you tap a ball on screen, and a live counter shows the taps of every other fan
of that team doing the same thing.

Naively that's one write per tap per user, which is exactly the shape of a
system that falls over during the only ninety seconds it matters. Instead:

1. **The app batches.** Taps during a celebration window collapse into a single
   call per goal, per user — not one per tap.
2. **The backend aggregates in memory** and flushes to sharded counters on a
   short timer. Writes are proportional to the number of running instances, not
   the number of fans.
3. **The read half of the flush is sampled**, so republishing the totals is
   sub-linear in instances too.
4. **The published total is a cached CDN object**, like scores — clients read it
   the same way they read everything else.
5. **Client reporting itself is sampled**, with the rate delivered by remote
   config so it can be tuned — or the whole feature switched off — without
   shipping an app update.

The result is a feature that feels like a stadium and costs like a counter.

## The client

SwiftUI, macOS 14+, no third-party UI frameworks.

**The overlay** is a transparent, click-through window above normal content: the
notch drop, the pinned score capsule, the particle burst, the tappable ball. It
tracks the active display, respects full-screen apps, and is designed to be
ignorable — an alert arrives, says its piece, and leaves.

**The pipeline** is polled state → diff → event router → overlay. The client
runs its own diff against what it last saw, so it derives events (goal, card,
penalty, VAR, substitution, kickoff, full-time) rather than being told about
them. A missed poll or a cold start therefore can't produce a phantom
notification, and a client that was asleep catches up quietly instead of
replaying an hour of history at you.

**Everything external is a protocol** — authentication, backend API, scores
feed. Three build configurations pick the implementations:

| | Debug | Staging | Release |
|---|---|---|---|
| Services | fakes, in-memory | staging cloud project | production |
| Sign-in | bypassed | staging OAuth | production OAuth |
| Network | *none whatsoever* | real | real |

The debug build plays a scripted demo matchday through the real event and
overlay pipeline with no network access at all. That's how animations get tuned,
how the demo video was filmed, and why a development session can't accidentally
write to a live counter.

## Sign-in, data and abuse

Sign-in is Google, with the ID token verified server-side before a session is
issued. The datastore is deny-all to clients: nothing reaches it except through
the backend's own admin path.

Public routes are rate-limited per user and per client address, internal
scheduler routes require authenticated service-to-service identity, the service
has a cap on how far it can scale out as a cost safeguard, and edge rate limits
protect the expensive path — the cache-busting request that would otherwise
become an origin read. The specific numbers stay in the private repo.

The account stores who you are and which teams you follow. Deleting the account
is one action in the app, and it deletes. Details are in the
[privacy policy](https://alldayidreamaboutsports.com/privacy).

## Release pipeline

| Stage | Where |
|---|---|
| Typecheck + unit tests on backend changes | CI, every PR |
| Backend deploy to staging | CI, on merge — keyless auth via workload identity federation, then a health smoke test |
| Backend deploy to production | manual dispatch |
| App build → archive → Developer ID signing → Apple notarization → styled DMG → notarize + staple the DMG | CI, on a version tag |
| Appcast generation, EdDSA signing, upload to the download CDN | **local, never CI** |

That last row is deliberate. The Sparkle signing key is the one credential that,
if lost or leaked, strands or hijacks every installed copy of the app. It lives
in a login keychain and signs releases on a laptop. CI never sees it.

Updates ship through Sparkle with delta patches. Staging and production have
separate buckets and separate download domains, so a test build cannot reach the
production update feed.

## Operating it

Remote config is the control plane, applied to running apps within seconds via a
real-time listener:

| Switch | Effect |
|---|---|
| Kill switch | running apps lock immediately — for a data-integrity or legal emergency |
| Minimum build | forces an update past a bad release |
| Latest build | shows a soft "update available" banner, no force |
| Celebration flag & sample rate | throttles or disables the only user-scaling path |
| Fetch interval | bounded, with a safe fallback so a bad edit can't create a tight billing loop |

There's a backup path for the kill switch through the scores CDN, for the case
where the config service is itself the outage — and the app stays killed until
*every* source that enabled it has cleared it, so recovery can't happen by
accident.

Logs are structured, and the messages that matter are the auditable ones: a
published state change logs before-and-after, so a wrong score, a stuck clock or
a missing scorer can be traced to the tick that caused it rather than argued
about.

---

## Things that turned out to matter

- **Polling beat pushing.** Not as a compromise — it's strictly better here.
  Same latency, a fraction of the moving parts, and a cost curve that flattens
  instead of climbing.
- **Gate on reality, not on config.** The system asks "is football happening?"
  and does nothing when the answer is no. Most of the savings came from that one
  question.
- **Batch at the edge you control.** Collapsing taps in the client is worth more
  than any amount of server-side cleverness downstream of it.
- **Keep the keys where the risk is.** Convenience in CI isn't worth the one
  credential that can't be rotated out of trouble.
- **Build the fake first.** An app that runs a full matchday with no network is
  what made the animation work — and the demo — possible at all.
