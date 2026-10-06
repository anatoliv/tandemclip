# TandemClip web cache policy

Shared design: `~/Projects/_method/web-cache-policy.md`. This repository owns
`deploy/nginx/default.conf`, copied from the previously host-only configuration
on 2026-09-28. The live container bind-mounts it at
`/opt/docker/tandemclip-web/nginx/default.conf`; editing this repository alone
does not change production.

- HTML and mutable site files revalidate on every visit.
- `appcast.xml` is never stored, so a pulled release reaches installed Macs.
- Version-named `.dmg` and `.delta` files are immutable for 30 days. Any
  missing path, including a download that is not published yet, answers 404
  with the branded `site/404.html` and `no-store, no-transform`. The release
  store retains those names; never replace bytes at an existing download URL.

To deploy a config change, copy `deploy/nginx/default.conf` to a temporary path
on the site host and run `nginx -t` in `nginx:1.27-alpine` on `proxy_net`. Back up the
live file, then copy the tested file to the bind-mount source and recreate only
`tandemclip_web` with `docker compose up -d --no-deps --force-recreate web` from
`/opt/docker/tandemclip-web`. Check the public `/`, `/appcast.xml`, and one
versioned DMG, including `Cache-Control` and status. The previous file is the
rollback; restore it and recreate the container if a check fails.
