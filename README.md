# Quadman

A self-hosted web UI for deploying and managing containerised services using **Podman** + **systemd Quadlets** — without Docker, without Kubernetes, without daemons running as root.

Built with Elixir, Phoenix LiveView, and SQLite. Inspired by Coolify and Dokploy, but Podman-native and deliberately simple.

---

## What it does

Quadman gives you a browser-based control panel over your Podman workloads:

- **Deploy services** by providing an image name. Quadman pulls the image, generates a [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) `.container` unit file, reloads the user systemd daemon, and starts the unit — all in a single Oban background job with a live log stream in the UI.
- **Import docker-compose.yaml** — paste a compose file and Quadman creates a stack and all its services automatically. The YAML is stored and editable in the UI; saving re-diffs the services and redeploys only what changed. See [Docker Compose import](#docker-compose-import) for details.
- **Manage environment variables** per service, with secret vars written to a `0600` env file and referenced via `EnvironmentFile=` rather than stored inline.
- **Group services into stacks** and deploy them together.
- **Auto-update images** — enable the "Auto-update image every 4 hours" toggle on any service and Quadman will pull the image periodically, compare digests, and trigger a redeploy only when a new image is available. Deployment history shows `auto-update` as the trigger.
- **Stream logs** in real time via `podman logs --follow`.
- **Monitor resource usage** — CPU and memory polled from the Podman stats API every 10 seconds and cached in ETS, so the dashboard stays fast regardless of how many services are running.
- **Inspect volumes** — browse named Podman volumes and their metadata from the Volumes page.
- **Automatic HTTPS via Caddy** — Caddy runs as a Podman container and starts automatically with Quadman. Set a domain on a service and Quadman registers a reverse-proxy route in Caddy's Admin API on deploy, giving you automatic HTTPS with zero config files.

Everything runs as a single Elixir release. No sidecars. No Postgres. SQLite in WAL mode handles concurrent LiveView connections without issue.

---

## Architecture

```
Browser ──HTTPS──► Caddy container (ports 80/443)
                       │
                       ├── quadman.yourdomain.com ──► Quadman (port 4000)
                       └── myapp.yourdomain.com   ──► Service container (port X)

Quadman (Phoenix/LiveView)
    │
    ├── SQLite (WAL mode)
    ├── Oban jobs (deploy queue)
    ├── PubSub (live updates)
    ├── Podman REST (Unix socket)
    └── systemctl (Quadlets)
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
| `Quadman.CaddyContainer` | Manages the Caddy Podman container (auto-started on boot) |
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

**Development (macOS or Linux):**
- Elixir 1.15+ / OTP 26+
- Node.js (for asset compilation)

No host Caddy installation required — Caddy runs as a Podman container managed by Quadman.

---

## Quick install (Linux)

```bash
# 1. Download and extract the latest release
sudo mkdir -p /opt/quadman
curl -fsSL https://github.com/mgrusso/quadman/releases/latest/download/quadman-linux-x86_64.tar.gz \
  | sudo tar -xzf - -C /opt/quadman/

# 2. Run the installer (reads the bundled quadman.service from the extracted release)
#    Creates the quadman system user, directories, sysctl rule (ports 80/443),
#    sudoers entry, subUID/subGID ranges, Podman socket, and the systemd unit.
curl -fsSL https://raw.githubusercontent.com/mgrusso/quadman/main/priv/deploy/install.sh | sudo bash

# 3. Edit the env file — set PHX_HOST to your domain at minimum
sudo nano /etc/quadman/env

# 4. Start (database migrations run automatically on first boot)
sudo systemctl enable --now quadman
```

On first boot, Quadman automatically deploys a Caddy container that listens on ports 80/443 and proxies both the Quadman UI and any services with domains configured. No manual Caddy setup needed.

**First-run setup — creating the admin account**

Navigate to `https://<your-host>/register`. The first user to register is automatically granted administrator access. Subsequent registrations are disabled by default.

**Enabling or disabling user registration**

Once logged in, go to **Settings → User Registration** and toggle the switch.

---

## Docker Compose import

Go to **Stacks → Import Compose**, paste your `docker-compose.yaml`, give the stack a name, and click **Import & deploy**. Quadman parses the file, creates a service per entry, and queues deployments immediately.

**Supported fields per service:**

| Compose field | Mapped to |
|---|---|
| `image:` | Service image (required) |
| `container_name:` | Service name (falls back to the service key) |
| `ports:` | Port mappings |
| `environment:` | Environment variables (list or map form) |
| `volumes:` | Bind-mount volumes (`/host:/container`) |
| `restart:` | Restart policy (`always`, `unless-stopped`, `on-failure`, `no`) |

**Not supported:** `build:` (must use a pre-built image — this will be flagged as an error), `networks:`, `depends_on:`, `deploy:` (Swarm), `env_file:`, `healthcheck:` (these are silently ignored with a warning).

Named volumes (e.g. `mydata:/app/data`) are skipped with a warning — only absolute bind-mount paths (`/host/path:/container/path`) are written to the Quadlet.

### Editing and redeploying

Once imported, the compose YAML is stored on the stack and visible in the **Compose YAML** editor on the stack detail page. Edit the YAML and click **Save & Redeploy** — Quadman diffs by service key and:
- **Creates** services present in the new YAML but not before
- **Updates** existing services (image, ports, volumes, env vars) and redeploys them
- **Removes** services no longer in the YAML (stops and deletes the unit)

---

## Reverse proxy (Caddy)

Quadman automatically manages a Caddy container that handles all incoming HTTPS traffic:

- **Quadman UI** is proxied via the `PHX_HOST` domain automatically — no configuration needed.
- **Service domains** — set a domain on any service and deploy. Quadman registers the route in Caddy on deploy and removes it when the service is deleted.
- **TLS certificates** are provisioned automatically by Caddy via Let's Encrypt.

You can manage the Caddy container from **Settings → Reverse Proxy**:
- View container status and Admin API reachability
- Stream live Caddy logs (useful for watching TLS certificate provisioning)
- Change the Caddy image tag (e.g. `2`, `2.9`, `alpine`)
- Restart or redeploy Caddy (e.g. to pick up a new image tag)

---

## Uninstall

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

---

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | ✅ | — | Generate with `mix phx.gen.secret` |
| `DATABASE_PATH` | ✅ | — | Absolute path to SQLite file, e.g. `/var/lib/quadman/quadman.db` |
| `PHX_HOST` | ✅ | — | Hostname for URL generation and Caddy TLS, e.g. `quadman.example.com` |
| `PORT` | | `4000` | HTTP port Quadman listens on (proxied by Caddy) |
| `PODMAN_SOCKET_PATH` | | `/run/user/<uid>/podman/podman.sock` | Path to the Podman Unix socket |
| `QUADLET_DIR` | | `~/.config/containers/systemd` | Where `.container` unit files are written |
| `QUADLET_SECRET_DIR` | | `~/.config/quadman/secrets` | Where secret env files are written (mode 0600) |
| `SYSTEMD_SCOPE` | | `user` | `user` for rootless Podman, `system` for root |
| `CADDY_ADMIN_URL` | | `http://localhost:2019` | Caddy Admin API base URL |

All variables can be placed in `/etc/quadman/env` (loaded by the systemd unit).

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
- **Caddy**: disabled in dev (auto-deploy only runs in production releases). Set `CADDY_ADMIN_URL` to point at a running Caddy instance to test routing locally.
- **Podman socket**: the Podman REST API is used for image pulls and stats. Without a running Podman socket, image pulls fail (deploy fails) but the UI, status polling, and Systemd stub all work fine.

---

## License

MIT
