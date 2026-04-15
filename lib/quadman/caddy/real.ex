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

        {:ok, %{status: 404}} ->
          add_route_to_array(id, route, upstream)

        {:ok, %{status: 400}} ->
          # Caddy has a duplicate @id in the routes array (corrupted state from
          # a previous failed deploy). Clean up all duplicates then add fresh.
          Logger.warning("Caddy: duplicate route #{id} detected, cleaning up")
          clean_and_add_route(id, route, upstream)

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
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 404}} ->
        Logger.info("Caddy: bootstrapping server #{@server_name}")
        server = %{"listen" => [":80", ":443"], "routes" => []}
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

  defp fetch_routes do
    case Req.get(base_req(), url: routes_url()) do
      {:ok, %{status: 200, body: list}} when is_list(list) -> list
      _ -> []
    end
  end

  # Add route to array, deduplicating by @id first to prevent duplicate errors.
  # Uses POST when the routes array already exists (replaces in-place),
  # falls back to PUT when the array doesn't exist yet (creates it).
  defp add_route_to_array(id, route, upstream) do
    url = routes_url()

    {current, method} =
      case Req.get(base_req(), url: url) do
        {:ok, %{status: 200, body: list}} when is_list(list) -> {list, :post}
        _ -> {[], :put}
      end

    deduped = Enum.reject(current, &(Map.get(&1, "@id") == id))
    new_routes = deduped ++ [route]

    req_fn = if method == :post, do: &Req.post/2, else: &Req.put/2

    case req_fn.(base_req(), url: url, json: new_routes) do
      {:ok, %{status: s}} when s in 200..299 ->
        Logger.info("Caddy: created route #{id} → #{upstream}")
        :ok

      {:ok, %{status: s, body: body}} ->
        {:error, "Caddy routes #{method} failed #{s}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Remove all duplicate entries for this ID from the array, then add fresh.
  defp clean_and_add_route(id, route, upstream) do
    add_route_to_array(id, route, upstream)
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
