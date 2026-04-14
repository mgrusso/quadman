# Quadman

A self-hosted web UI for deploying and managing containerised services using **Podman** + **systemd Quadlets** — without Docker, without Kubernetes, without daemons running as root.

Built with Elixir, Phoenix LiveView, and SQLite. Inspired by Coolify and Dokploy, but Podman-native and deliberately simple.

---

## What it does

Quadman gives you a browser-based control panel over your Podman workloads:

- **Deploy services** by providing an image name. Quadman pulls the image, generates a [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) `.container` unit file, reloads the user systemd daemon, and starts the unit — all in a single Oban background job with a live log stream in the UI.
- **Manage environment variables** per service, with secret vars written to a `0600` env file and referenced via `EnvironmentFile=` rather than stored inline.
- **Group services into stacks** and deploy them together.
- **Stream logs** in real time via `journalctl --follow`.
- **Monitor resource usage** — CPU and memory polled from the Podman stats API every 10 seconds and cached in ETS, so the dashboard stays fast regardless of how many services are running.
- **Integrate with Caddy** — set a domain on a service and Quadman registers a reverse-proxy route in Caddy's Admin API on deploy, giving you automatic HTTPS with zero Nginx config files.

Everything runs as a single Elixir release. No sidecars. No Postgres. SQLite in WAL mode handles concurrent LiveView connections without issue.

---

## Architecture

```
Browser ──HTTPS──► Caddy ──► Quadman (Phoenix/LiveView, port 4000)
                                │
                    ┌───────────┼───────────────┐
                    │           │               │
               SQLite       Oban jobs      PubSub
             (WAL mode)   (deploy queue)  (live updates)
                    │           │
              Podman REST    systemctl
              (Unix socket)  (Quadlets)
```

**Core components:**

| Module | Role |
|---|---|
| `Quadman.Accounts` | Auth via `Phoenix.Token` — no UserToken table |
| `Quadman.Services` | Service CRUD, env var management, status refresh |
| `Quadman.Stacks` | Grouping services into named stacks |
| `Quadman.Deployments` | Deployment records, log streaming via PubSub |
| `Quadman.Podman` | HTTP client over Podman's Unix socket (`Req`) |
| `Quadman.Quadlets` | EEx templates → `.container` unit files |
| `Quadman.Systemd` | `systemctl` wrapper (stub available for macOS dev) |
| `Quadman.Caddy` | Caddy Admin API client for dynamic route management |
| `Quadman.Workers.DeployWorker` | Oban job: pull → write Quadlet → reload → start → poll |
| `Quadman.StatusPoller` | GenServer polling `systemctl is-active` every 30s |
| `Quadman.PodmanStatsPoller` | GenServer polling `podman stats` every 10s into ETS |

---

## Requirements

**Server:**
- Linux (RHEL/CentOS 8+, Fedora, Debian 11+, Ubuntu 22.04+)
- Podman 4.4+ (rootless, user systemd session)
- systemd with Quadlet support (systemd ≥ 236, Podman ≥ 4.4)
- `loginctl enable-linger <user>` to keep the user session alive

**Optional:**
- [Caddy](https://caddyserver.com) for automatic HTTPS and service routing

**Development (macOS or Linux):**
- Elixir 1.15+ / OTP 26+
- Node.js (for asset compilation)

---

## Quick install (Linux)

> **Note:** Pre-built release tarballs are not yet published. Build from source using the steps below.

```bash
# Clone the repo and build a release
git clone https://github.com/mgrusso/quadman.git
cd quadman
mix deps.get --only prod
mix assets.deploy
MIX_ENV=prod mix release

# The tarball is at _build/prod/quadman-*.tar.gz
tar -czf quadman.tar.gz -C _build/prod/rel/quadman .

# Run the installer (creates user, dirs, systemd unit)
curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/install.sh | sudo bash

# With Caddy installed automatically:
curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/install.sh | sudo bash -s -- --caddy

# Extract the release
sudo tar -xzf quadman.tar.gz -C /opt/quadman/

# Edit the env file (set PHX_HOST at minimum)
sudo nano /etc/quadman/env

# Run migrations
sudo -u quadman /opt/quadman/bin/quadman eval "Quadman.Release.migrate()"

# Start
sudo systemctl enable --now quadman
```

The default admin account is seeded on first migration:

| Field | Default |
|---|---|
| Email | `admin@quadman.local` |
| Password | `changeme123!` |

**Change the password** by setting `ADMIN_EMAIL` and `ADMIN_PASSWORD` before running seeds, or directly in the database.

---

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | ✅ | — | Generate with `mix phx.gen.secret` |
| `DATABASE_PATH` | ✅ | — | Absolute path to SQLite file, e.g. `/var/lib/quadman/quadman.db` |
| `PHX_HOST` | ✅ | — | Hostname for URL generation, e.g. `quadman.example.com` |
| `PORT` | | `4000` | HTTP port Quadman listens on |
| `PODMAN_SOCKET_PATH` | | `/run/user/<uid>/podman/podman.sock` | Path to the Podman Unix socket |
| `QUADLET_DIR` | | `~/.config/containers/systemd` | Where `.container` unit files are written |
| `QUADLET_SECRET_DIR` | | `~/.config/quadman/secrets` | Where secret env files are written (mode 0600) |
| `SYSTEMD_SCOPE` | | `user` | `user` for rootless Podman, `system` for root |
| `CADDY_ENABLED` | | `false` | Set `true` to enable Caddy Admin API integration |
| `CADDY_ADMIN_URL` | | `http://localhost:2019` | Caddy Admin API base URL |

All variables can be placed in `/etc/quadman/env` (loaded by the systemd unit).

---

## Caddy integration

Quadman can automatically register HTTPS routes in [Caddy](https://caddyserver.com) when you deploy a service. No Caddyfile edits needed — routes are added and removed via the Caddy Admin API.

**Setup:**

1. Install Caddy (the install script handles this with `--caddy`)
2. Configure `/etc/caddy/Caddyfile` — see `priv/deploy/Caddyfile.example`
3. Set `CADDY_ENABLED=true` in `/etc/quadman/env`
4. In the Quadman UI, set a domain on any service (e.g. `myapp.example.com`)
5. Deploy — Quadman registers the Caddy route and Caddy provisions a certificate automatically

Routes are tagged with `@id: quadman-<service>` in Caddy's config, so Quadman can update or remove them independently.

---

## Building from source

```bash
git clone https://github.com/mgrusso/quadman.git
cd quadman

# Install dependencies
mix deps.get

# Create the database and run migrations
mix ecto.setup

# Start in development mode (uses systemd and Caddy stubs)
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000). Log in with `admin@quadman.local` / `changeme123!`.

### Building a release

```bash
mix assets.deploy
MIX_ENV=prod mix release
```

The release tarball is written to `_build/prod/quadman-*.tar.gz`.

---

## Development notes

- **macOS**: `Quadman.Systemd.Stub` is active in dev — all `systemctl` calls are no-ops that return `:ok`. The deploy pipeline runs end-to-end but skips real unit management.
- **Caddy**: disabled by default in dev (`CADDY_ENABLED=false`). Set `CADDY_ENABLED=true` and point `CADDY_ADMIN_URL` at a running Caddy instance to test routing locally.
- **Podman socket**: the Podman REST API is used for image pulls and stats. Without a running Podman socket, image pulls fail (deploy fails) but the UI, status polling, and Systemd stub all work fine.

---

## License

MIT
