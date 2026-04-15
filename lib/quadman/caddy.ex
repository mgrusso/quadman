defmodule Quadman.Caddy do
  @moduledoc """
  Manages Caddy reverse-proxy routes for deployed services via the Caddy Admin API.

  When a service has a `domain` set, the deploy pipeline calls `upsert_route/2`
  after the unit becomes active. This adds (or replaces) a reverse-proxy entry in
  Caddy's JSON config with no reload required.

  Routes are tagged with `"@id": "quadman-{service_name}"` so they can be updated
  or removed by ID without knowing their array index.

  Set `CADDY_ENABLED=false` to disable all Caddy API calls (default in dev).
  """

  @callback ping() :: :ok | {:error, term()}
  @callback upsert_route(domain :: String.t(), upstream :: String.t()) :: :ok | {:error, term()}
  @callback remove_route(domain :: String.t()) :: :ok | {:error, term()}
  @callback list_routes() :: {:ok, [map()]} | {:error, term()}

  defp adapter do
    Application.get_env(:quadman, :caddy_adapter, __MODULE__.Real)
  end

  defp enabled? do
    Quadman.AppSettings.get("caddy_enabled", "false") == "true"
  end

  def ping do
    if enabled?(), do: adapter().ping(), else: {:error, :disabled}
  end

  def upsert_route(domain, upstream) do
    if enabled?(), do: adapter().upsert_route(domain, upstream), else: :ok
  end

  def remove_route(domain) do
    if enabled?(), do: adapter().remove_route(domain), else: :ok
  end

  def list_routes do
    if enabled?(), do: adapter().list_routes(), else: {:ok, []}
  end

  @doc """
  Extracts the host-side port from the first port_mapping entry.
  e.g. "8080:80" → "127.0.0.1:8080", "80" → "127.0.0.1:80"
  Returns nil if port_mappings is empty.
  """
  def upstream_from_port_mappings([]), do: nil
  def upstream_from_port_mappings([first | _]) do
    host_port =
      case String.split(first, ":") do
        [host, _container] -> host
        [port] -> port
      end

    "127.0.0.1:#{host_port}"
  end

  @doc "Caddy route ID for a service (stable across deploys)."
  def route_id(service_name), do: "quadman-#{service_name}"
end
