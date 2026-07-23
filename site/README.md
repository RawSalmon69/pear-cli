# Pear.app landing page

Static site for https://pear.phanthawas.dev — plain `index.html` + `style.css`,
no build step, no external fonts/scripts/CDNs. The Download button resolves the
latest `companion-v*` GitHub release client-side (first `.zip` asset of the
newest non-draft, non-prerelease `companion-v*` tag); with JS off or the API
rate-limited it falls back to the releases page.

**Deploy:** Cloudflare Pages serves this directory. Either connect the repo in
the dashboard (Workers & Pages → project → build command: *none*, output dir:
`site`) so every push to `main` redeploys, or push manually with
`npx wrangler pages deploy site --project-name pear-landing`. The custom domain
`pear.phanthawas.dev` is attached under the Pages project → Custom domains.
To update the page: edit files here, commit to `main` (or rerun the wrangler
command). No version bumps needed — the download button finds the newest
release by itself.
