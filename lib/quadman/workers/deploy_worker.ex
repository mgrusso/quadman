defmodule Quadman.Workers.DeployWorker do
  @moduledoc """
  Oban job that executes the full deploy pipeline for a service:

    1. Pull image via Podman REST API
    2. Get image digest
    3. Write secrets env file (mode 0600)
    4. Render and write .container Quadlet file
    5. Update service record with quadlet_path + unit_name
    6. systemctl daemon-reload
    7. systemctl start/restart <unit>
    8. Poll is-active up to 10x with 1s sleep
    9. Register Caddy reverse-proxy route (non-fatal, if domain is set)
   10. Update deployment status + broadcast via PubSub
  """

  use Oban.Worker, queue: :deployments, max_attempts: 3

  require Logger

  alias Quadman.{Deployments, Services, Quadlets, Systemd, Podman, Caddy}

  @poll_attempts 10
  @poll_interval_ms 1_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"deployment_id" => deployment_id}}) do
    deployment = Deployments.get_deployment!(deployment_id)
    service = Services.get_service_with_env!(deployment.service_id)

    log = fn message, level ->
      Deployments.append_log(deployment_id, message, level)
    end

    Deployments.update_deployment_status(deployment, "running")
    broadcast_status(deployment_id, "running")

    with {:ok, digest} <- step_pull_image(service, log),
         :ok <- step_write_quadlet(service, log),
         :ok <- step_daemon_reload(log),
         :ok <- step_start_unit(service, log),
         :ok <- step_poll_active(service, log) do
      # Reload the service to pick up quadlet_path/unit_name written during step_write_quadlet
      service = Services.get_service!(service.id)
      step_register_caddy(service, log)

      Deployments.update_deployment_status(deployment, "succeeded", image_digest: digest)
      broadcast_status(deployment_id, "succeeded")
      Services.update_service_status(service, "running")
      log.("Deploy succeeded", "info")
      :ok
    else
      {:error, reason} ->
        Deployments.update_deployment_status(deployment, "failed")
        broadcast_status(deployment_id, "failed")
        Services.update_service_status(service, "failed")
        step_collect_container_logs(service, log)
        log.("Deploy failed: #{reason}", "error")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp step_pull_image(service, log) do
    log.("Pulling image #{service.image}...", "info")

    case Podman.pull_image(service.image) do
      :ok ->
        case Podman.image_digest(service.image) do
          {:ok, digest} ->
            log.("Image pulled. Digest: #{digest}", "info")
            {:ok, digest}

          {:error, reason} ->
            log.("Could not get digest: #{reason}", "warn")
            {:ok, nil}
        end

      {:error, reason} ->
        {:error, "image pull failed: #{reason}"}
    end
  end

  defp step_write_quadlet(service, log) do
    log.("Writing Quadlet files...", "info")
    env_vars = service.environment_variables

    # Create host-side volume directories if they don't exist yet
    Enum.each(service.volumes, fn mapping ->
      host_path = mapping |> String.split(":") |> List.first()
      if host_path && !String.starts_with?(host_path, "/") == false do
        case File.mkdir_p(host_path) do
          :ok -> log.("Ensured volume directory: #{host_path}", "info")
          {:error, reason} -> log.("Could not create #{host_path}: #{reason}", "warn")
        end
      end
    end)

    with :ok <- Quadlets.write_secrets(service, env_vars),
         {:ok, path} <- Quadlets.write_container(service, env_vars) do
      unit_name = Quadlets.unit_name(service.name)

      Services.update_service(service, %{quadlet_path: path, unit_name: unit_name})

      log.("Quadlet written to #{path}", "info")
      :ok
    end
  end

  defp step_daemon_reload(log) do
    log.("Running systemctl daemon-reload...", "info")

    case Systemd.daemon_reload() do
      :ok -> :ok
      {:error, reason} -> {:error, "daemon-reload failed: #{reason}"}
    end
  end

  defp step_start_unit(service, log) do
    unit = Quadlets.unit_name(service.name)
    log.("Starting unit #{unit}...", "info")

    result =
      case service.status do
        "running" -> Systemd.restart(unit)
        _ -> Systemd.start(unit)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, "unit start failed: #{reason}"}
    end
  end

  defp step_poll_active(service, log) do
    unit = Quadlets.unit_name(service.name)
    log.("Waiting for #{unit} to become active...", "info")
    poll_active(unit, @poll_attempts, log)
  end

  defp poll_active(_unit, 0, _log), do: {:error, "unit did not become active in time"}

  defp poll_active(unit, attempts_left, log) do
    case Systemd.is_active(unit) do
      {:ok, "active"} ->
        :ok

      {:ok, "activating"} ->
        Process.sleep(@poll_interval_ms)
        poll_active(unit, attempts_left - 1, log)

      {:ok, status} ->
        {:error, "unit is #{status}"}

      {:error, reason} ->
        log.("is-active error: #{reason}", "warn")
        Process.sleep(@poll_interval_ms)
        poll_active(unit, attempts_left - 1, log)
    end
  end

  # ---------------------------------------------------------------------------
  # Caddy route registration (non-fatal)
  # ---------------------------------------------------------------------------

  defp step_register_caddy(%{domain: nil}, _log), do: :ok
  defp step_register_caddy(%{domain: ""}, _log), do: :ok

  defp step_register_caddy(service, log) do
    upstream = Caddy.upstream_from_port_mappings(service.port_mappings)

    if upstream do
      log.("Registering Caddy route: #{service.domain} → #{upstream}", "info")

      case Caddy.upsert_route(service.domain, upstream) do
        :ok ->
          log.("Caddy route registered.", "info")

        {:error, reason} ->
          log.("Caddy route failed (non-fatal): #{inspect(reason)}", "warn")
      end
    else
      log.("No port mappings — skipping Caddy route registration.", "warn")
    end
  end

  # ---------------------------------------------------------------------------
  # Container log capture (on failure)
  # ---------------------------------------------------------------------------

  defp step_collect_container_logs(service, log) do
    container_name = "systemd-#{service.name}"
    podman = System.find_executable("podman") || "/usr/bin/podman"

    # podman logs works on stopped/exited containers; exit 125 means not found.
    case System.cmd(podman, ["logs", "--tail", "100", container_name],
           stderr_to_stdout: true) do
      {output, 0} when output != "" ->
        log.("--- Container output ---", "warn")
        output |> String.split("\n", trim: true) |> Enum.each(&log.(&1, "info"))

      _ ->
        # Container was never created — fall back to journalctl via the lingering
        # user session DBUS socket (at /run/user/<uid>/bus).
        collect_journalctl_logs(service.name, log)
    end
  rescue
    _ -> :ok
  end

  defp collect_journalctl_logs(service_name, log) do
    unit = "#{service_name}.service"
    journalctl = System.find_executable("journalctl") || "/usr/bin/journalctl"

    # Read the system journal (quadman must be in the systemd-journal group).
    # Unit lifecycle and start-failure messages are written there, not the user journal.
    {output, _} =
      System.cmd(journalctl, ["-u", unit, "--no-pager", "-n", "100", "--output", "short"],
        stderr_to_stdout: true)

    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.reject(&journal_meta_line?/1)

    if lines != [] do
      log.("--- systemd journal (#{unit}) ---", "warn")
      Enum.each(lines, &log.(&1, "info"))
    end
  rescue
    _ -> :ok
  end

  # Filter out journalctl header/hint lines that carry no diagnostic value.
  defp journal_meta_line?(line) do
    String.starts_with?(line, "-- ") or String.contains?(line, "Hint:")
  end

  # ---------------------------------------------------------------------------
  # PubSub broadcast
  # ---------------------------------------------------------------------------

  defp broadcast_status(deployment_id, status) do
    Phoenix.PubSub.broadcast(
      Quadman.PubSub,
      "deployment:#{deployment_id}",
      {:status, status}
    )
  end
end
