# Contributing

This project is open source but **not open to outside contributions**. Pull
requests from people other than the maintainer will be closed without review.
The app ships through the Mac App Store, and keeping every line under a single
copyright holder is what keeps that distribution compatible with the GPL.

You are welcome to:

- Open an issue for a bug or an idea.
- Fork it and change it however you like under [GPL-3.0-only](LICENSE); see
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for what the license covers.
- Report security problems privately as described in [SECURITY.md](SECURITY.md).

## Running it yourself

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
build instructions in [app/README.md](app/README.md). A fork needs its own cloud
projects, API-Football key, signing identity and bundle id; do not point write
or load-test tools at this project's production services.

Backend deployments must pass the reusable verification workflow for the exact
commit. Fork pull requests never receive deployment credentials.
