# The configuration of your reverse proxy

Written by `prepare_environment.sh` from `.env`: the public URLs, the ports the stack listens on and the `PROXY` settings. Again by `./prepare_environment.sh --upgrade` (and `--render-units`, `--render-proxy`): a file you changed is then kept as `<file>.before-<...>-<time>`. See docs/reverse-proxy.md.

Pick the file of your proxy, put it where it says, reload:

- `nginx.conf`: nginx. Into `/etc/nginx/conf.d/` (or `sites-enabled/`), with the certificates where `ssl_certificate` says first: with nginx running, `certbot certonly --nginx -d <host>` (or `--webroot`) for each host; `--standalone` only on a host with no web server, it needs port 80 for itself. Then `nginx -t && systemctl reload nginx`.
- `Caddyfile`: Caddy. As your Caddyfile, or `import` it from yours, then `caddy reload`. Your own snippets go in `caddy.d/` next to it (see its first lines): they stay when it is written again.
- `traefik.yml`: Traefik, its file provider (`providers.file`). Into its directory, Traefik reads it by itself.

These three proxy to the ports of this host (127.0.0.1): your proxy runs on this host.

`PROXY=caddy`: the bundled Caddy runs `Caddyfile.bundled`, on the host's network, compose/caddy.yml of `COMPOSE_FILE`: `docker compose restart caddy` after a change.
