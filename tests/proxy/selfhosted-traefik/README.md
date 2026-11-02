# The configuration of your reverse proxy

Written by `prepare_environment.sh` from `.env`: the public URLs, the ports the stack listens on and the `PROXY` settings. Again by `./prepare_environment.sh --upgrade` (and `--render-units`, `--render-proxy`): a file you changed is then kept as `<file>.before-<...>-<time>`. See docs/reverse-proxy.md.

Pick the file of your proxy, put it where it says, reload:

- `nginx.conf`: nginx. Into `/etc/nginx/conf.d/` (or `sites-enabled/`), with the certificates where `ssl_certificate` says first (`certbot certonly --standalone -d <host>`, nginx stopped), then `nginx -t && systemctl reload nginx`.
- `Caddyfile`: Caddy. As your Caddyfile, or `import` it from yours, then `caddy reload`. Your own snippets go in `caddy.d/` next to it (see its first lines): they stay when it is written again.
- `traefik.yml`: Traefik, its file provider (`providers.file`). Into its directory, Traefik reads it by itself.

These three proxy to the ports of this host (127.0.0.1): your proxy runs on this host.

`PROXY=traefik`: `traefik-compose.yml` is in `COMPOSE_FILE`: the labels of your Traefik's Docker provider on the public containers, which it puts on `ffs-proxy` (`TRAEFIK_NETWORK`), a network of this stack with Traefik on it and nothing else. `docker compose up -d` applies them.
