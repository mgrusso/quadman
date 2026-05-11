defmodule Quadman.Compose do
  @moduledoc """
  Parses docker-compose YAML into Quadman service attribute maps.

  Returns `{:ok, service_attrs, warnings}` where `service_attrs` is a list of maps
  ready to create Service + EnvironmentVariable records, and `warnings` is a list
  of human-readable strings about unsupported or ignored fields.

  Services with `build:` instead of `image:` are skipped with an error-level warning.
  """

  @doc """
  Parses a docker-compose YAML string.

  Returns `{:ok, [service_attrs], warnings}` or `{:error, reason}`.
  Each service_attrs map has keys:
    :compose_service_key, :name, :image, :port_mappings, :volumes, :restart_policy, :env_vars
  where :env_vars is a list of `%{key: k, value: v, is_secret: false}` maps.
  """
  def parse(yaml) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"services" => services}} when is_map(services) and map_size(services) > 0 ->
        {attrs_list, warnings} = parse_services(services)

        if attrs_list == [] do
          {:error, "No valid services found — check that each service has an 'image:' and no 'build:' key"}
        else
          {:ok, attrs_list, warnings}
        end

      {:ok, _} ->
        {:error, "No 'services:' section found in YAML"}

      {:error, %{message: msg}} ->
        {:error, "YAML parse error: #{msg}"}

      {:error, reason} ->
        {:error, "YAML parse error: #{inspect(reason)}"}
    end
  end

  @doc "Extracts the top-level name: field from a compose YAML string, if present."
  def extract_name(yaml) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{"name" => name}} when is_binary(name) -> {:ok, slugify(name)}
      _ -> :not_found
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp parse_services(services) do
    Enum.reduce(services, {[], []}, fn {key, svc}, {attrs_acc, warn_acc} ->
      svc = svc || %{}

      case parse_service(key, svc) do
        {:skip, reasons} ->
          {attrs_acc, warn_acc ++ reasons}

        {:ok, attrs, service_warnings} ->
          {attrs_acc ++ [attrs], warn_acc ++ service_warnings}
      end
    end)
  end

  defp parse_service(key, svc) do
    cond do
      Map.has_key?(svc, "build") ->
        {:skip, ["'#{key}' has a 'build:' key — only pre-built images are supported; skipped"]}

      not Map.has_key?(svc, "image") ->
        {:skip, ["'#{key}' has no 'image:' key; skipped"]}

      true ->
        warnings = collect_ignored_warnings(key, svc)

        name = svc |> Map.get("container_name", key) |> slugify()
        ports = parse_ports(Map.get(svc, "ports", []))
        {env_vars, env_warnings} = parse_environment(Map.get(svc, "environment", []))
        {volumes, vol_warnings} = parse_volumes(Map.get(svc, "volumes", []))
        restart = parse_restart(Map.get(svc, "restart", "on-failure"))

        attrs = %{
          compose_service_key: key,
          name: name,
          image: svc["image"],
          port_mappings: ports,
          volumes: volumes,
          restart_policy: restart,
          env_vars: env_vars
        }

        {:ok, attrs, warnings ++ env_warnings ++ vol_warnings}
    end
  end

  defp collect_ignored_warnings(key, svc) do
    ignored_keys = [
      {"networks", "not supported — services communicate via the host network"},
      {"depends_on", "not supported — services deploy in parallel"},
      {"deploy", "Swarm mode fields not supported"},
      {"env_file", "not supported — add those variables manually in Quadman"},
      {"healthcheck", "not supported"},
      {"links", "not supported — use 'host.containers.internal' for inter-container communication"},
      {"extends", "not supported"}
    ]

    for {k, reason} <- ignored_keys, Map.has_key?(svc, k) do
      "'#{key}.#{k}' #{reason}; ignored"
    end
  end

  defp parse_environment(env) when is_map(env) do
    vars =
      Enum.map(env, fn {k, v} ->
        %{key: normalize_env_key(k), value: to_string(v || ""), is_secret: false}
      end)

    {vars, []}
  end

  defp parse_environment(env) when is_list(env) do
    vars =
      Enum.map(env, fn
        entry when is_binary(entry) ->
          case String.split(entry, "=", parts: 2) do
            [k, v] -> %{key: normalize_env_key(k), value: v, is_secret: false}
            [k] -> %{key: normalize_env_key(k), value: "", is_secret: false}
          end

        entry when is_map(entry) ->
          [{k, v}] = Map.to_list(entry)
          %{key: normalize_env_key(k), value: to_string(v || ""), is_secret: false}
      end)

    {vars, []}
  end

  defp parse_environment(_), do: {[], []}

  defp parse_ports(ports) when is_list(ports) do
    Enum.map(ports, fn
      port when is_integer(port) -> to_string(port)
      port when is_binary(port) -> port
      port when is_map(port) ->
        target = Map.get(port, "target", "")
        published = Map.get(port, "published", "")
        if published != "", do: "#{published}:#{target}", else: "#{target}"
    end)
  end

  defp parse_ports(_), do: []

  defp parse_volumes(volumes) when is_list(volumes) do
    Enum.reduce(volumes, {[], []}, fn vol, {acc, warn} ->
      case parse_volume_entry(vol) do
        {:bind, v} -> {acc ++ [v], warn}
        {:named, name} -> {acc, warn ++ ["Named volume '#{name}' is not supported — only bind mounts are; ignored"]}
        :skip -> {acc, warn}
      end
    end)
  end

  defp parse_volumes(_), do: {[], []}

  defp parse_volume_entry(vol) when is_binary(vol) do
    host = vol |> String.split(":", parts: 3) |> List.first()

    if String.starts_with?(host, "/") do
      {:bind, vol}
    else
      {:named, host}
    end
  end

  defp parse_volume_entry(%{"type" => "bind", "source" => src, "target" => tgt} = vol) do
    suffix = if Map.get(vol, "read_only", false), do: ":ro", else: ""
    {:bind, "#{src}:#{tgt}#{suffix}"}
  end

  defp parse_volume_entry(%{"type" => "volume", "source" => src}), do: {:named, src}

  defp parse_volume_entry(_), do: :skip

  defp parse_restart("always"), do: "always"
  defp parse_restart("unless-stopped"), do: "always"
  defp parse_restart("on-failure"), do: "on-failure"
  defp parse_restart("on-success"), do: "on-success"
  defp parse_restart("no"), do: "no"
  defp parse_restart(_), do: "on-failure"

  defp normalize_env_key(k) do
    normalized =
      k
      |> to_string()
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9_]/, "_")

    # Ensure first char is a letter (required by EnvironmentVariable changeset)
    if String.match?(normalized, ~r/^[A-Z]/) do
      normalized
    else
      "K_" <> normalized
    end
  end

  defp slugify(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
  end
end
