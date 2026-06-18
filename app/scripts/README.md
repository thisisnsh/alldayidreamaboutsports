# App Release Scripts

`publish.sh` is the only manual release script. CI builds, signs, notarizes, and
staples the DMG; this script generates the Sparkle appcast, delta updates, and
optional HTML release notes, then uploads those files to Cloudflare R2.

Prereqs:

- Sparkle `generate_appcast` installed locally at
  `$SPARKLE_HOME/bin/generate_appcast` (`SPARKLE_HOME` defaults to
  `/Users/thisisnsh/projects/Sparkle`).
- Sparkle EdDSA private key in your Keychain.
- Node 22+.

## Publish To Staging

Staging is the default so a normal publish does not reach production users:

Create the local env file once:

```sh
cp app/scripts/.publish.env.example app/scripts/.publish.env
```

Fill in the three `R2_*` values from the Cloudflare R2 dashboard plus
`CLOUDFLARE_ZONE_ID` and a `CLOUDFLARE_API_TOKEN` that can purge cache, then
publish:

```sh
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

## Remove A Bad Version

The appcast is Sparkle's source of truth. Do not only delete a bad DMG from R2:
if `appcast.xml` still advertises that version, users can still be offered the
update and then hit a download failure.

To stop offering a version:

1. Remove the bad version's files from the local release directory:
   `~/Releases/AllDayIDreamAboutSports/staging` or
   `~/Releases/AllDayIDreamAboutSports/release`.
   Remove the `.dmg`, matching `.html`, and any `.delta` files involving that
   version.
2. Rerun `publish.sh` for that channel with a known-good DMG still present in
   the local release directory. This regenerates and uploads `appcast.xml`.
3. Let `publish.sh` purge `${DOWNLOAD_HOST}/appcast.xml` from Cloudflare.
4. Delete the bad `.dmg`, `.html`, and orphan `.delta` objects from R2 if you
   want them gone from storage.

This only stops future update offers. Users who already installed the bad build
need a newer fixed build; use the app's force-update/min-build path if they must
move forward immediately.

## Notes

The script accepts R2-named credentials from `app/scripts/.publish.env` by
default. Set `R2_ENV_FILE=/path/to/file` to use a different env file.

Uploads use the same direct R2 pattern as `tester/fake-publisher.ts`: the
Cloudflare R2 S3-compatible endpoint through `@aws-sdk/client-s3`. The first
upload run installs `app/scripts` Node dependencies if needed.

After upload, `publish.sh` purges `${DOWNLOAD_HOST}/appcast.xml` from
Cloudflare so a republished appcast is visible immediately even though release
objects carry a long cache TTL.

Sparkle release notes are included by placing an `.html` file beside the DMG
with the same basename. `publish.sh --notes` handles that staging automatically.
