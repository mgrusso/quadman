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

```bash
# 1. Run the installer
#    Creates the quadman system user, directories, sysctl rule (ports 80/443),
#    sudoers entry, subUID/subGID ranges, and the systemd unit.
curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/install.sh | sudo bash

# 2. Download and extract the latest release
curl -fsSL https://github.com/mgrusso/quadman/releases/latest/download/quadman-linux-x86_64.tar.gz \
  | sudo tar -xzf - -C /opt/quadman/

# 3. Re-run install to register the service file from the extracted release
curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/install.sh | sudo bash

# 4. Edit the env file — set PHX_HOST to your domain at minimum
sudo nano /etc/quadman/env

# 5. Start (database migrations run automatically on first boot)
sudo systemctl enable --now quadman
```

**First-run setup — creating the admin account**

Quadman has no pre-seeded accounts. On a fresh install, navigate to `https://<your-host>/register`. The first user to register is automatically granted administrator access. Subsequent registrations are disabled by default.

**Enabling or disabling user registration**

Once logged in, go to **Settings → User Registration** and toggle the switch. When disabled, the `/register` page shows a "registrations are currently disabled" notice and no account can be created. When enabled, any visitor can register a new account — turn this off again once your users are set up.

---

## Uninstall

To completely remove Quadman and all its data from the server:

```bash
curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/uninstall.sh | sudo bash
```

The script will ask you to type `yes` before doing anything. It removes:

- The `quadman` systemd service (stopped and disabled)
- The Podman socket and all user-session container units for the `quadman` user
- `/opt/quadman` — release binaries
- `/var/lib/quadman` — database and persistent data (including Caddy data)
- `/etc/quadman` — configuration and env file
- `/etc/systemd/system/quadman.service`
- `/etc/sudoers.d/quadman`
- `/etc/sysctl.d/99-quadman.conf`
- The `quadman` subUID/subGID entries from `/etc/subuid` and `/etc/subgid`
- The `quadman` system user

Podman itself is **not** removed — only the Quadman-managed infrastructure.

If you used a non-default user or install directory, pass the same flags you gave to `install.sh`:

```bash
curl -fsSL .../uninstall.sh | sudo bash -s -- --user myuser --dir /srv/quadman
```

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

Quadman can automatically register HTTPS routes in [Caddy](https://caddyserver.com) when you deploy a service. No Caddyfile editing needed — Caddy runs as a Podman container managed by Quadman itself, and routes are added and removed via its Admin API.

**Setup:**

1. Run the install script — it sets `net.ipv4.ip_unprivileged_port_start=80` via sysctl so rootless containers can bind ports 80 and 443
2. Open the Quadman UI and go to **Settings → Caddy**
3. Click **Deploy Caddy container** — Quadman pulls `caddy:2`, writes a minimal Caddyfile, creates the Quadlet unit, and starts it
4. Enable **Route management** in the same section
5. Set a domain on any service (e.g. `myapp.example.com`) and deploy — Quadman registers the route in Caddy and Caddy provisions a certificate automatically

Routes are tagged with `@id: quadman-<service>` in Caddy's config, so Quadman can update or remove them independently.

To upgrade Caddy, undeploy and redeploy from Settings — Podman will pull the latest `caddy:2` image.

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
