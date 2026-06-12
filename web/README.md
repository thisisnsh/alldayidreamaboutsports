# Website — GitHub Pages

Static, no build step: `index.html` (landing, with the live notch-pill demo),
`privacy.html`, `style.css`, `CNAME`.

## Deploy

Pushing to `main` with changes under `web/` runs
`.github/workflows/web-deploy.yml` and publishes to GitHub Pages.

One-time repo settings (see also TODO.md):
1. GitHub → Settings → Pages → **Source: GitHub Actions**.
2. Custom domain `alldayidreamaboutsports.com` (the `CNAME` file ships with the
   artifact) + **Enforce HTTPS** once the cert is issued.
3. DNS at the registrar/Cloudflare: apex `A` records →
   `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
   (or CNAME-flattened to `thisisnsh.github.io`). If the zone is on Cloudflare,
   set the record to **DNS only** (grey cloud) so GitHub can issue the cert.

## Local preview

```sh
python3 -m http.server -d web 8000   # http://localhost:8000
```

Design notes: sky/daydream theme, day + night via `prefers-color-scheme`,
Fredoka + Atkinson Hyperlegible from Google Fonts, zero images (emoji + CSS
only), `prefers-reduced-motion` respected. The download button points at
`download.alldayidreamaboutsports.com/latest` — create that R2 redirect (or
update the href to the current DMG) when shipping.
