import Config

if System.get_env("PHX_SERVER") do
  config :quadman, QuadmanWeb.Endpoint, server: true
end

# ---------------------------------------------------------------------------
# Quadman runtime settings (apply in all envs so they work in dev too)
# ---------------------------------------------------------------------------

if podman_socket = System.get_env("PODMAN_SOCKET_PATH") do
  config :quadman, podman_socket_path: podman_socket
end

if quadlet_dir = System.get_env("QUADLET_DIR") do
  config :quadman, quadlet_dir: quadlet_dir
end

if secret_dir = System.get_env("QUADLET_SECRET_DIR") do
  config :quadman, quadlet_secret_dir: secret_dir
end

if scope = System.get_env("SYSTEMD_SCOPE") do
  config :quadman, systemd_scope: scope
end

# Caddy Admin API URL (caddy_enabled is now managed via the UI in AppSettings)
if caddy_url = System.get_env("CADDY_ADMIN_URL") do
  config :quadman, caddy_admin_url: caddy_url
end

# ---------------------------------------------------------------------------
# Production-only config
# ---------------------------------------------------------------------------

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise "DATABASE_PATH env var is missing. Example: /var/lib/quadman/quadman.db"

  config :quadman, Quadman.Repo,
    database: database_path,
    journal_mode: :wal,
    cache_size: -64000,
    foreign_keys: :on,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    show_sensitive_data_on_connection_error: true

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE env var is missing. Generate with: mix phx.gen.secret"

  host = System.get_env("PHX_HOST") || raise "PHX_HOST env var is missing."
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :quadman, QuadmanWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base

  config :quadman, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # In prod, use the real adapters (not stubs)
  config :quadman, systemd_adapter: Quadman.Systemd.Real
  config :quadman, caddy_adapter: Quadman.Caddy.Real
end
