# Inter-Jail Communication Patterns

How multiple containers work together in parasa.

## Networking

All containers use `ip4=inherit` / `ip6=inherit`, sharing the host's
network stack. Jails communicate via loopback (`127.0.0.1`). Each
service binds to a unique port.

## The reverse proxy pattern

A common pattern: nginx as a shared reverse proxy forwarding to
application jails.

```
                zbamidbar/web (nullfs)
               +---------------------------+
               |  conf.d/recipya.conf      |  <- written by recipya's compose.sh
               |  conf.d/other-app.conf    |  <- written by other app's compose.sh
               |  ...                      |
               +------+-----------+--------+
                      |           |
            (ro mount)|           |(rw mount)
                      v           v
               +----------+   +----------+
               |  nginx   |   | recipya  |
               |  :80     |   | :8078    |
               |  includes|   +----------+
               |  conf.d/*|        ^
               +----+-----+       |
                    |  proxy_pass  |
                    +--------------+
          recipes.* -> 127.0.0.1:8078
```

### How it works

1. A shared ZFS dataset (`zbamidbar/web`) is nullfs-mounted into both
   jails:
   - nginx mounts it **read-only** at `/usr/local/www`
   - app jails mount it **read-write** at `/usr/local/www`

2. nginx's `compose.sh` adds an `include` directive:
   ```
   include /usr/local/www/conf.d/*.conf;
   ```

3. Each app's `compose.sh` writes its own nginx config snippet into
   `conf.d/` on the shared dataset. For example, recipya writes
   `conf.d/recipya.conf`:
   ```
   server {
       listen 80;
       server_name recipes.*;
       location / {
           proxy_pass http://127.0.0.1:8078;
       }
   }
   ```

4. When nginx starts, it picks up all `conf.d/*.conf` snippets
   automatically. No coupling between recipes -- nginx doesn't need
   to know about recipya, and recipya doesn't need to know about nginx's
   internal config structure.

### Adding a new app behind nginx

1. Create the app's container recipe
2. In the recipe's `mount.fstab`, add a **rw** nullfs mount of
   `zbamidbar/web`
3. In the recipe's `compose.sh` `post_pkg`, write a nginx config
   snippet to `/usr/local/www/conf.d/<app>.conf`
4. Choose a unique port for the app
5. Reload nginx: `jexec nginx service nginx reload`

### Shared dataset structure

```
zbamidbar/web/
  conf.d/              Nginx config snippets (one per app)
    recipya.conf
    gitea.conf
    ...
  static/              Optional shared static assets
```

Each app owns its own config file. Rebuilding an app refreshes its
snippet. Other apps are unaffected.

## Data isolation

Each jail has its own data datasets under
`zbamidbar/container-data/<name>/`. The shared `zbamidbar/web` dataset
is the only cross-jail data surface. App-specific data (databases,
uploads, etc.) stays in the app's own `var` dataset.

For recipya:
- Database and uploads: `/var/db/recipya/` (on the var data dataset)
- Config: `XDG_CONFIG_HOME=/var/db/recipya` directs recipya to store
  its config.json and SQLite databases there
- Nginx snippet: `/usr/local/www/conf.d/recipya.conf` (on shared dataset)

## Startup order

With `ip4=inherit`, jail startup order generally doesn't matter for
networking -- the port isn't occupied until the service starts. However,
nginx should start after app jails if you want zero failed proxy
attempts on boot. The `jail.conf` `depend` directive can enforce this:

```
nginx {
    depend = "recipya";
    ...
}
```
