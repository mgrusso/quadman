defmodule Quadman.Caddy.Real do
  @moduledoc """
  Caddy Admin API client. Talks to `http://localhost:2019` (or CADDY_ADMIN_URL).

  Route lifecycle:
    - `upsert_route/2`: PUT /id/{route_id} to update; if 404, POST to routes array.
    - `remove_route/1`: DELETE /id/{route_id}; ignores 404 (already gone).

  Routes include `"@id"` so Caddy registers them in its ID namespace, enabling
  future updates without array-index bookkeeping.

  The HTTP server "quadman_services" is bootstrapped on first `upsert_route` call
  if it doesn't exist in Caddy's config yet.
  """

  @behaviour Quadman.Caddy

  require Logger

  @server_name "quadman_services"

  defp admin_url do
    Application.get_env(:quadman, :caddy_admin_url, "http://localhost:2019")
  end

  defp base_req do
    Req.new(base_url: admin_url(), receive_timeout: 10_000)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @impl true
  def ping do
    case Req.get(base_req(), url: "/config/") do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s}} -> {:error, "HTTP #{s}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def upsert_route(domain, upstream) do
    with :ok <- ensure_http_server() do
      route = build_route(domain, upstream)
      id = Quadman.Caddy.route_id(domain)

      case Req.put(base_req(), url: "/id/#{id}", json: route) do
        {:ok, %{status: s}} when s in 200..299 ->
          Logger.info("Caddy: updated route #{id} → #{upstream}")
          :ok

        {:ok, %{status: 404}} ->
          # Route doesn't exist yet — append it
          case Req.post(base_req(),
                 url: "/config/apps/http/servers/#{@server_name}/routes",
                 json: route
               ) do
            {:ok, %{status: s}} when s in 200..299 ->
              Logger.info("Caddy: created route #{id} → #{upstream}")
              :ok

            {:ok, %{status: s, body: body}} ->
              {:error, "Caddy POST route failed #{s}: #{inspect(body)}"}

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, %{status: s, body: body}} ->
          {:error, "Caddy PUT route failed #{s}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def remove_route(domain) do
    id = Quadman.Caddy.route_id(domain)

    case Req.delete(base_req(), url: "/id/#{id}") do
      {:ok, %{status: s}} when s in [200, 204, 404] ->
        Logger.info("Caddy: removed route #{id}")
        :ok

      {:ok, %{status: s, body: body}} ->
        {:error, "Caddy DELETE route failed #{s}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_routes do
    case Req.get(base_req(), url: "/config/apps/http/servers/#{@server_name}/routes") do
      {:ok, %{status: 200, body: body}} -> {:ok, body || []}
      {:ok, %{status: 404}} -> {:ok, []}
      {:ok, %{status: s, body: body}} -> {:error, "Caddy list routes #{s}: #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Bootstrap
  # ---------------------------------------------------------------------------

  defp ensure_http_server do
    url = "/config/apps/http/servers/#{@server_name}"

    case Req.get(base_req(), url: url) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 404}} ->
        Logger.info("Caddy: bootstrapping server #{@server_name}")
        server_config = %{"listen" => [":80", ":443"], "routes" => []}

        case Req.put(base_req(), url: url, json: server_config) do
          {:ok, %{status: s}} when s in 200..299 -> :ok
          {:ok, %{status: s, body: b}} -> {:error, "Caddy server bootstrap failed #{s}: #{inspect(b)}"}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Route builder
  # ---------------------------------------------------------------------------

  defp build_route(domain, upstream) do
    %{
      "@id" => Quadman.Caddy.route_id(domain),
      "match" => [%{"host" => [domain]}],
      "handle" => [
        %{
          "handler" => "reverse_proxy",
          "upstreams" => [%{"dial" => upstream}],
          "health_checks" => %{
            "passive" => %{
              "fail_duration" => "30s",
              "max_fails" => 3,
              "unhealthy_request_count" => 10
            }
          }
        }
      ],
      "terminal" => true
    }
  end
end
