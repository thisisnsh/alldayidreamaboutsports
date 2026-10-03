# CI/CD workflows

| Workflow | Trigger | What |
|---|---|---|
| `backend-ci.yml` | PRs + main pushes touching `backend/` | `npm ci`, typecheck, vitest |
| `backend-deploy.yml` | main pushes touching `backend/` (→ staging); manual dispatch for prod | `gcloud run deploy --source` via Workload Identity Federation, then authenticated `/internal/healthz` and anonymous-denial smoke tests |

The website lives in the separate public repo
`thisisnsh/alldayidreamaboutsports.com` (GitHub Pages "Deploy from a branch", no
workflow). Secrets/vars each workflow needs are listed in `infra/README.md`
(GitHub secrets/vars summary table).

The macOS app has no workflow: it is built, archived and uploaded to the Mac
App Store from Xcode (see `app/README.md`).
