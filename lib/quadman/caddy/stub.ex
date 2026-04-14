defmodule Quadman.Caddy.Stub do
  @moduledoc """
  Dev/test stub — all Caddy API calls are no-ops.
  Activate via: `config :quadman, caddy_adapter: Quadman.Caddy.Stub`
  """

  @behaviour Quadman.Caddy

  require Logger

  @impl true
  def ping do
    Logger.debug("[Caddy.Stub] ping → :ok")
    :ok
  end

  @impl true
  def upsert_route(domain, upstream) do
    Logger.debug("[Caddy.Stub] upsert_route #{domain} → #{upstream} (no-op)")
    :ok
  end

  @impl true
  def remove_route(domain) do
    Logger.debug("[Caddy.Stub] remove_route #{domain} (no-op)")
    :ok
  end

  @impl true
  def list_routes do
    {:ok, []}
  end
end
