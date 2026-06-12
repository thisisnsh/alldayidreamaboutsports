# CI/CD workflows

| Workflow | Trigger | What |
|---|---|---|
| `backend-ci.yml` | PRs + main pushes touching `backend/` | `npm ci`, typecheck, vitest |
| `app-ci.yml` | PRs + main pushes touching `app/` | XcodeGen + `xcodebuild` for Debug (fake backend) **and** Release (real), unsigned |
| `backend-deploy.yml` | main pushes touching `backend/` (→ staging); manual dispatch for prod | `gcloud run deploy --source` via Workload Identity Federation, then `/healthz` smoke test |
| `app-release.yml` | tag `v*` | XcodeGen → archive → Developer ID sign → notarize app → DMG → notarize DMG → staple → Sparkle appcast → upload R2 → GitHub Release |
| `web-deploy.yml` | main pushes touching `web/` | GitHub Pages deploy (Settings → Pages → Source: GitHub Actions) |

Secrets/vars each workflow needs are listed in `infra/README.md`
(GitHub secrets/vars summary table). Build numbers in releases come from
`GITHUB_RUN_NUMBER`, which is what Remote Config `min_build` compares against.
