defmodule Quadman.CaddyContainer do
  @moduledoc """
  Manages Caddy as a rootless Podman container via a Quadlet unit.

  Caddy runs with host networking so it can bind ports 80, 443, and 2019.
  Requires `net.ipv4.ip_unprivileged_port_start=80` on the host (set by install.sh).

  The Caddyfile written here only enables the Admin API — actual route config
  is managed dynamically by `Quadman.Caddy` via the Admin API.
  """

  alias Quadman.Systemd
  require Logger

  @unit_name "caddy.service"

  @caddyfile """
  {
      admin localhost:2019
      auto_https off
  }
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def deploy do
    data_dir = caddy_data_dir()
    caddyfile_path = Path.join(data_dir, "Caddyfile")
    quadlet_path = quadlet_path()

    with :ok <- File.mkdir_p(Path.join(data_dir, "data")),
         :ok <- File.mkdir_p(Path.join(data_dir, "config")),
         :ok <- write_caddyfile(caddyfile_path),
         :ok <- File.write(quadlet_path, render_quadlet(data_dir, caddyfile_path)),
         :ok <- Systemd.daemon_reload(),
         :ok <- Systemd.start(@unit_name) do
      Logger.info("CaddyContainer: deployed and started")
      :ok
    else
      {:error, reason} = err ->
        Logger.error("CaddyContainer deploy failed: #{inspect(reason)}")
        err
    end
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

  @doc "Returns :running, :stopped, or :not_deployed."
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
    # Only write if it doesn't already exist — preserve any manual edits.
    if File.exists?(path) do
      :ok
    else
      File.write(path, @caddyfile)
    end
  end

  defp render_quadlet(data_dir, caddyfile_path) do
    """
    [Unit]
    Description=Caddy reverse proxy (managed by Quadman)
    After=network-online.target

    [Container]
    Image=docker.io/library/caddy:2
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
