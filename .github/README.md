# CI/CD workflows

| Workflow | Trigger | Checks |
|---|---|---|
| `backend-ci.yml` | All PRs/main pushes; reusable by deployments | Backend/tester clean install without lifecycle scripts, typechecks, tests, build, dependency audit, infrastructure tests |
| `app-ci.yml` | All PRs/main pushes | Remote-data security tests and unsigned Debug build using the committed Swift lockfile |
| `security.yml` | PRs/main pushes, weekly, manual | Full-history secret scanning and recurring dependency audits |
| `backend-deploy.yml` | Relevant main pushes to staging; manual prod | Reuses backend verification for the exact commit before obtaining deployment credentials; authenticated health and anonymous-denial checks |

Actions are pinned to commit SHAs. Dependabot proposes npm and Actions updates.
Fork PR verification has read-only permissions and receives no deployment
identity. Original icon assets are GPL-3.0-only; no audio is bundled.

Before accepting outside contributions, configure GitHub main protection with
required backend, app, and secret checks, review requirements, and no force
pushes. Keep prod restricted to main and require an appropriate deployment
reviewer, and require approval before running workflows from outside forks.
These account settings are separate from committed workflow files; verify the
exact check names from the first workflow runs before making them required.

The macOS release is still archived/uploaded manually from Xcode; CI never
uploads to the App Store. Deployment secrets/variables are documented in
[infra/README.md](../infra/README.md).
