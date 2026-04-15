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
      require Logger
      # Small delay to let the endpoint and DB fully settle
      Process.sleep(2_000)

      case Quadman.CaddyContainer.ensure_deployed() do
        :ok ->
          # Give Caddy a moment to be ready after (re)deploy
          Process.sleep(2_000)
          register_caddy_routes()

        {:error, reason} ->
          Logger.warning("Caddy auto-deploy failed: #{inspect(reason)}")
      end

      # Ensure caddy_enabled defaults to true
      if Quadman.AppSettings.get("caddy_enabled") == nil do
        Quadman.AppSettings.put("caddy_enabled", "true")
      end
    end
  end

  defp register_caddy_routes do
    require Logger

    # Register the Quadman UI itself — Caddyfile no longer does this
    phx_host = Application.get_env(:quadman, :phx_host, System.get_env("PHX_HOST"))
    phx_port = Application.get_env(:quadman, :phx_port, 4000)

    if phx_host && phx_host != "localhost" do
      case Quadman.Caddy.upsert_route(phx_host, "127.0.0.1:#{phx_port}") do
        :ok -> Logger.info("Caddy: registered Quadman UI route #{phx_host}")
        {:error, r} -> Logger.warning("Caddy: failed to register UI route: #{inspect(r)}")
      end
    end

    # Re-register all running service routes (in case Caddy was restarted)
    Quadman.Services.list_services()
    |> Enum.filter(&(&1.domain && &1.status == "running"))
    |> Enum.each(fn svc ->
      upstream = Quadman.Caddy.upstream_from_port_mappings(svc.port_mappings)
      if upstream do
        case Quadman.Caddy.upsert_route(svc.domain, upstream) do
          :ok -> Logger.info("Caddy: re-registered route #{svc.domain} → #{upstream}")
          {:error, r} -> Logger.warning("Caddy: failed to re-register #{svc.domain}: #{inspect(r)}")
        end
      end
    end)
  end
end
