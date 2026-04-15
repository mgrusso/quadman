defmodule Quadman.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      QuadmanWeb.Telemetry,
      Quadman.Repo,
      {Ecto.Migrator,
        repos: Application.fetch_env!(:quadman, :ecto_repos),
        skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:quadman, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Quadman.PubSub},
      {Oban, Application.fetch_env!(:quadman, Oban)},
      Quadman.StatusPoller,
      Quadman.PodmanStatsPoller,
      # Start to serve requests, typically the last entry
      QuadmanWeb.Endpoint,
      # Auto-deploy Caddy reverse proxy after endpoint is up
      {Task, fn -> caddy_autostart() end}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Quadman.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    QuadmanWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # Skip in dev (use mix ecto.migrate); run automatically in releases
    System.get_env("RELEASE_NAME") == nil
  end

  # Only auto-deploy Caddy in production releases, not in dev/test.
  defp caddy_autostart do
    if System.get_env("RELEASE_NAME") do
      # Small delay to let the endpoint and DB fully settle
      Process.sleep(2_000)

      case Quadman.CaddyContainer.ensure_deployed() do
        :ok -> :ok
        {:error, reason} ->
          require Logger
          Logger.warning("Caddy auto-deploy failed: #{inspect(reason)}")
      end

      # Ensure caddy_enabled defaults to true
      if Quadman.AppSettings.get("caddy_enabled") == nil do
        Quadman.AppSettings.put("caddy_enabled", "true")
      end
    end
  end
end
