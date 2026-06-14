# CI/CD workflows

| Workflow | Trigger | What |
|---|---|---|
| `backend-ci.yml` | PRs + main pushes touching `backend/` | `npm ci`, typecheck, vitest |
| `backend-deploy.yml` | main pushes touching `backend/` (→ staging); manual dispatch for prod | `gcloud run deploy --source` via Workload Identity Federation, then `/healthz/` smoke test |
| `app-release.yml` | tag `v*` | XcodeGen → archive → Developer ID sign → notarize app → styled DMG (`create-dmg`) → notarize DMG → staple → **upload-artifact**. No appcast/R2/Release — those are local (`app/scripts/publish.sh`). |

The website lives in the separate public repo
`thisisnsh/alldayidreamaboutsports.com` (GitHub Pages "Deploy from a branch", no
workflow). Secrets/vars each workflow needs are listed in `infra/README.md`
(GitHub secrets/vars summary table). Build numbers in releases come from
`GITHUB_RUN_NUMBER`, which is what Remote Config `min_build` compares against.
