# App Release Scripts

`publish.sh` is the only manual release script. CI builds, signs, notarizes, and
staples the DMG; this script generates the Sparkle appcast, delta updates, and
optional HTML release notes, then uploads those files to Cloudflare R2.

## Publish To Staging

Staging is the default so a normal publish does not reach production users:

```sh
export R2_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
export R2_ACCESS_KEY_ID=...
export R2_SECRET_ACCESS_KEY=...

app/scripts/publish.sh ~/Downloads/AllDayIDreamAboutSports-1.0.0.dmg \
  --notes ~/Downloads/AllDayIDreamAboutSports-1.0.0.html
```

This updates `download-staging.alldayidreamaboutsports.com`. Use a staging app
build with a lower build number to test the full Sparkle update path there.

## Validate Before Production

After publishing to staging, inspect the generated files locally:

```sh
xmllint --noout ~/Releases/AllDayIDreamAboutSports/staging/appcast.xml
npx sparkle-validator ~/Releases/AllDayIDreamAboutSports/staging/appcast.xml --strict
```

Then verify the staging app can see the update, render the HTML release notes,
download the DMG or delta, verify signatures, and install successfully.

## Publish To Production

Only publish production intentionally:

```sh
app/scripts/publish.sh ~/Downloads/AllDayIDreamAboutSports-1.0.0.dmg \
  --notes ~/Downloads/AllDayIDreamAboutSports-1.0.0.html \
  --release
```

Without `--release` or `CHANNEL=release`, `publish.sh` targets staging.

## Notes

The script accepts R2-named credentials. It maps them to `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` only because the AWS CLI is being used as an
S3-compatible client for R2.

Sparkle release notes are included by placing an `.html` file beside the DMG
with the same basename. `publish.sh --notes` handles that staging automatically.
