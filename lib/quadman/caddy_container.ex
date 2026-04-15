defmodule Quadman.CaddyContainer do
  @moduledoc """
  Manages Caddy as a rootless Podman container via a Quadlet unit.

  Caddy runs with host networking so it can bind ports 80, 443, and 2019.
  It is automatically deployed on application startup via `ensure_deployed/0`.

  Caddy serves as the sole entry point — it terminates TLS for all service
  domains AND for the Quadman UI itself (proxied to 127.0.0.1:4000).

  Route config for services is managed dynamically by `Quadman.Caddy` via
  the Caddy Admin API. The Quadman UI route is written statically into the
  Caddyfile so it survives Caddy restarts without DB access.
  """

  alias Quadman.Systemd
  require Logger

  @unit_name "caddy.service"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Called at application startup. Deploys Caddy if not already deployed.
  """
  def ensure_deployed do
    if deployed?() do
      case status() do
        :running -> :ok
        _ -> Systemd.start(@unit_name)
      end
    else
      Logger.info("CaddyContainer: auto-deploying on first boot")
      deploy()
    end
  end

  def deploy do
    data_dir = caddy_data_dir()
    caddyfile_path = Path.join(data_dir, "Caddyfile")
    quadlet_path = quadlet_path()
    tag = caddy_tag()

    with :ok <- File.mkdir_p(Path.join(data_dir, "data")),
         :ok <- File.mkdir_p(Path.join(data_dir, "config")),
         :ok <- write_caddyfile(caddyfile_path),
         :ok <- File.write(quadlet_path, render_quadlet(data_dir, caddyfile_path, tag)),
         :ok <- Systemd.daemon_reload(),
         :ok <- Systemd.start(@unit_name) do
      Logger.info("CaddyContainer: deployed and started (image tag: #{tag})")
      :ok
    else
      {:error, reason} = err ->
        Logger.error("CaddyContainer deploy failed: #{inspect(reason)}")
        err
    end
  end

  def redeploy do
    _ = Systemd.stop(@unit_name)
    deploy()
  end

  def undeploy do
    _ = Systemd.stop(@unit_name)
    _ = File.rm(quadlet_path())
    Systemd.daemon_reload()
    Logger.info("CaddyContainer: undeployed")
    :ok
  end

  def restart do
    Systemd.restart(@unit_name)
  end

  @doc "Returns :running, {:stopped, status}, or :not_deployed."
  def status do
    if deployed?() do
      case Systemd.is_active(@unit_name) do
        {:ok, s} when s in ["active", "activating"] -> :running
        {:ok, s} -> {:stopped, s}
      end
    else
      :not_deployed
    end
  end

  @doc "True if the Quadlet file exists on disk."
  def deployed? do
    File.exists?(quadlet_path())
  end

  @doc "The image tag currently configured (from AppSettings or default)."
  def caddy_tag do
    Quadman.AppSettings.get("caddy_image_tag", "2")
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp caddy_data_dir do
    Application.get_env(:quadman, :caddy_data_dir, "/var/lib/quadman/caddy")
  end

  defp quadlet_dir do
    Application.get_env(:quadman, :quadlet_dir, Path.expand("~/.config/containers/systemd"))
  end

  defp quadlet_path do
    Path.join(quadlet_dir(), "caddy.container")
  end

  defp write_caddyfile(path) do
    host = Application.get_env(:quadman, :phx_host, System.get_env("PHX_HOST", "localhost"))
    port = Application.get_env(:quadman, :phx_port, 4000)

    caddyfile = """
    {
        admin localhost:2019
    }

    #{host} {
        reverse_proxy 127.0.0.1:#{port}
    }
    """

    File.write(path, caddyfile)
  end

  defp render_quadlet(data_dir, caddyfile_path, tag) do
    """
    [Unit]
    Description=Caddy reverse proxy (managed by Quadman)
    After=network-online.target

    [Container]
    Image=docker.io/library/caddy:#{tag}
    Network=host
    Volume=#{Path.join(data_dir, "data")}:/data
    Volume=#{Path.join(data_dir, "config")}:/config
    Volume=#{caddyfile_path}:/etc/caddy/Caddyfile:ro

    [Service]
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=default.target
    """
  end
end
