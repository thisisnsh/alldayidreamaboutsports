# alldayidreamaboutsports.com

Public website for **All Day I Dream About Sports** — the macOS menu bar app for
FIFA World Cup 2026. Static, no build step: `index.html` (landing, with the live
notch-pill demo), `privacy/index.html`, `style.css`, `CNAME`, `.nojekyll`.

This repo is public **only** so GitHub Pages is free; the app source lives in a
separate private repo. The download button points at
`https://download.alldayidreamaboutsports.com/latest` (Cloudflare R2), and the
Sparkle update feed is also on R2 — releases are published from the private repo's
release flow, not here.

## Deploy

GitHub Pages, **Deploy from a branch** — no workflow, no Actions minutes:

1. Settings → Pages → **Source: Deploy from a branch** → `main` / `/ (root)`.
   Every push to `main` republishes.
2. Custom domain `alldayidreamaboutsports.com` (the `CNAME` file ships in the
   repo) + **Enforce HTTPS** once the cert is issued.
3. DNS at the registrar/Cloudflare: apex `A` records →
   `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
   (or CNAME-flattened to `thisisnsh.github.io`). If the zone is on Cloudflare,
   set the records to **DNS only** (grey cloud) so GitHub can issue the cert.

> A custom domain can bind to only one repo at a time — make sure it's removed
> from any other repo's Pages settings first.

## Local preview

```sh
python3 -m http.server 8000   # http://localhost:8000
```

Design notes: sky/daydream theme, day + night via `prefers-color-scheme`,
Fredoka + Atkinson Hyperlegible from Google Fonts, zero images (emoji + CSS
only), `prefers-reduced-motion` respected.
