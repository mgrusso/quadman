defmodule Quadman.Podman do
  @moduledoc """
  HTTP client for the Podman REST API over a Unix socket.

  All requests go through `Req` with `unix_socket:` pointing to the configured socket path.
  Podman REST API base: http://d/v5.0.0/libpod/
  """

  defp socket_path do
    Application.get_env(:quadman, :podman_socket_path, "/run/user/1000/podman/podman.sock")
  end

  defp base_req do
    Req.new(
      base_url: "http://d/v5.0.0/libpod",
      unix_socket: socket_path(),
      receive_timeout: 120_000
    )
  end

  @doc """
  Pull an image. The Podman pull endpoint streams newline-delimited JSON and
  always returns HTTP 200 — even on failure. We scan each JSON line for an
  `"error"` key to detect real failures.
  Returns `:ok` or `{:error, reason}`.
  """
  def pull_image(image) do
    case Req.post(base_req(), url: "/images/pull", params: [reference: image]) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        check_pull_stream(body)

      {:ok, %{status: status, body: body}} ->
        {:error, "pull failed #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "pull request error: #{inspect(reason)}"}
    end
  end

  # The body is either a binary of newline-delimited JSON or already decoded.
  defp check_pull_stream(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.find_value(:ok, fn line ->
      case Jason.decode(line) do
        {:ok, %{"error" => err}} -> {:error, "pull error: #{err}"}
        _ -> nil
      end
    end)
  end

  # Req may decode a single JSON object if Content-Type is application/json
  defp check_pull_stream(%{"error" => err}), do: {:error, "pull error: #{err}"}
  defp check_pull_stream(_), do: :ok

  @doc """
  Inspect an image and return its digest.
  Returns `{:ok, digest}` or `{:error, reason}`.
  """
  def image_digest(image) do
    case Req.get(base_req(), url: "/images/#{URI.encode(image, &URI.char_unreserved?/1)}/json") do
      {:ok, %{status: 200, body: body}} ->
        digest = get_in(body, ["Digest"]) || get_in(body, ["Id"])
        {:ok, digest}

      {:ok, %{status: status, body: body}} ->
        {:error, "image inspect failed #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "image inspect error: #{inspect(reason)}"}
    end
  end

  @doc """
  List running containers. Returns `{:ok, [container_map]}` or `{:error, reason}`.
  """
  def list_containers do
    case Req.get(base_req(), url: "/containers/json", params: [all: true]) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "list containers #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Fetch stats for all running containers (no-stream).
  Returns `{:ok, [stats_map]}` or `{:error, reason}`.
  """
  def stats do
    case Req.get(base_req(), url: "/containers/stats", params: [stream: false]) do
      {:ok, %{status: 200, body: body}} ->
        # Podman streams newline-delimited JSON; Req may hand us the raw string.
        parsed =
          case body do
            b when is_map(b) -> b
            b when is_binary(b) ->
              b |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
            _ -> %{}
          end

        entries = Map.get(parsed, "Stats") || []
        {:ok, entries}

      {:ok, %{status: status, body: body}} ->
        {:error, "stats #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Check if the Podman socket is reachable.
  """
  def ping do
    case Req.get(base_req(), url: "/_ping") do
      {:ok, %{status: 200}} -> :ok
      _ -> {:error, :unreachable}
    end
  end

  @doc """
  List all Podman volumes. Returns `{:ok, [volume_map]}` or `{:error, reason}`.
  """
  def list_volumes do
    case Req.get(base_req(), url: "/volumes/json") do
      {:ok, %{status: 200, body: body}} -> {:ok, List.wrap(body)}
      {:ok, %{status: status, body: body}} -> {:error, "list volumes #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Create a named volume. Idempotent — returns `:ok` if the volume already exists.
  Returns `:ok` or `{:error, reason}`.
  """
  def create_volume(name) do
    case Req.post(base_req(), url: "/volumes/create", json: %{"Name" => name}) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, "create volume #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc """
  Delete a named volume. Returns `:ok` if deleted or not found.
  Returns `:ok` or `{:error, reason}`.
  """
  def delete_volume(name) do
    case Req.delete(base_req(), url: "/volumes/#{URI.encode(name, &URI.char_unreserved?/1)}") do
      {:ok, %{status: s}} when s in [204, 404] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, "delete volume #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
