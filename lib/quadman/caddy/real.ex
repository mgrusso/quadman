defmodule Quadman.Caddy.Real do
  @moduledoc """
  Caddy Admin API client. Talks to `http://localhost:2019` (or CADDY_ADMIN_URL).

  Route lifecycle:
    - `upsert_route/2`: tries PUT /id/{route_id} first; on 404, reads the full
      routes array and PUTs it back with the new route appended. This avoids
      POST-to-path which fails when parent nodes don't exist yet.
    - `remove_route/1`: DELETE /id/{route_id}; ignores 404 (already gone).

  Routes include `"@id"` so Caddy registers them in its ID namespace.

  The HTTP server "quadman_services" is bootstrapped via the full /config/
  endpoint on first use so parent nodes are always created correctly.
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

        {:ok, %{status: status}} when status in [400, 404] ->
          # 404 = route ID not registered yet; 400 = duplicate @id in array.
          # Best-effort delete any stale entry, then POST a single route to append.
          Req.delete(base_req(), url: "/id/#{id}")
          append_route(id, route, upstream)

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
  # Bootstrap — creates the quadman_services HTTP server if absent.
  # Works via specific sub-paths only (never touches root /config/) to avoid
  # 409 conflicts when a config already exists.
  # ---------------------------------------------------------------------------

  defp ensure_http_server do
    case Req.get(base_req(), url: "/config/apps/http/servers/#{@server_name}") do
      {:ok, %{status: 200, body: server}} ->
        # Server exists — ensure it has TLS connection policies so Caddy
        # terminates TLS and provisions certs via auto-HTTPS for all routes.
        if is_map(server) && !Map.has_key?(server, "tls_connection_policies") do
          Logger.info("Caddy: patching missing tls_connection_policies on #{@server_name}")
          Req.put(base_req(),
            url: "/config/apps/http/servers/#{@server_name}/tls_connection_policies",
            json: [%{}]
          )
        end
        :ok

      {:ok, %{status: s}} when s in [400, 404] ->
        # 404 = parent exists, server key absent; 400 = parent path itself absent.
        # Both mean the server hasn't been created yet — bootstrap it.
        Logger.info("Caddy: bootstrapping server #{@server_name}")
        server = %{"listen" => [":443"], "tls_connection_policies" => [%{}], "routes" => []}
        bootstrap_server(server)

      {:ok, %{status: s, body: b}} ->
        {:error, "Caddy server check failed #{s}: #{inspect(b)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Try increasingly broad paths until one accepts the PUT.
  defp bootstrap_server(server) do
    candidates = [
      {"/config/apps/http/servers/#{@server_name}", server},
      {"/config/apps/http", %{"servers" => %{@server_name => server}}},
      {"/config/apps", %{"http" => %{"servers" => %{@server_name => server}}}}
    ]

    result =
      Enum.find_value(candidates, fn {path, body} ->
        case Req.put(base_req(), url: path, json: body) do
          {:ok, %{status: s}} when s in 200..299 -> :ok
          _ -> nil
        end
      end)

    result || {:error, "Caddy: could not create #{@server_name} server at any config path"}
  end

  # ---------------------------------------------------------------------------
  # Route array helpers
  # ---------------------------------------------------------------------------

  defp routes_url, do: "/config/apps/http/servers/#{@server_name}/routes"

  # Append a single route object to the routes array.
  # ensure_http_server/0 guarantees the array exists before this is called.
  # Caddy's POST to an array path appends one element (not replaces).
  defp append_route(id, route, upstream) do
    case Req.post(base_req(), url: routes_url(), json: route) do
      {:ok, %{status: s}} when s in 200..299 ->
        Logger.info("Caddy: created route #{id} → #{upstream}")
        :ok

      {:ok, %{status: s, body: body}} ->
        {:error, "Caddy POST route failed #{s}: #{inspect(body)}"}

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
