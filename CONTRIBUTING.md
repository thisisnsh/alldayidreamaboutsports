# Contributing

Original code and bundled app icons are licensed under GPL-3.0-only; see
[LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Contributions must be yours to submit under those terms. Do not add credentials,
unlicensed media, or production fixtures containing private data.

Use a topic branch and submit a focused pull request explaining the behavior
change and validation. Security reports belong in the private channel described
in [SECURITY.md](SECURITY.md).

## Local checks

Use Node 24 and macOS 14+ with Xcode for the native app:

```sh
cd backend
npm ci --ignore-scripts
npm run typecheck && npm test && npm run build && npm audit
cd ../tester
npm ci --ignore-scripts
npm run typecheck && npm audit
cd ..
python3 -m unittest discover -s infra/test -v
bash app/scripts/test-security.sh
```

The unsigned Debug build needs no private Firebase plist. Follow the reproducible
build instructions in [app/README.md](app/README.md). Review and commit package
lockfiles with dependency changes. Use your own cloud projects and signing
identity for a fork; do not point write or load-test tools at production.

Backend deployments must pass the reusable verification workflow for the exact
commit. Maintainers should protect main, require review/checks, and restrict the
production environment before accepting outside contributions. Fork pull
requests must never receive deployment credentials.
