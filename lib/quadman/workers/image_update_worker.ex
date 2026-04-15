defmodule Quadman.Workers.ImageUpdateWorker do
  @moduledoc """
  Oban periodic job that checks every 4 hours whether a newer image is available
  for services with `auto_update: true`. If the local digest differs from the
  registry digest after a fresh pull, it triggers a new deployment.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Quadman.{Services, Deployments, Podman}
  import Ecto.Query

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("ImageUpdateWorker: checking auto-update services")

    services =
      Services.Service
      |> where([s], s.auto_update == true and s.status == "running")
      |> Quadman.Repo.all()

    Logger.info("ImageUpdateWorker: #{length(services)} service(s) to check")

    Enum.each(services, &check_and_update/1)

    :ok
  end

  defp check_and_update(service) do
    Logger.info("ImageUpdateWorker: checking #{service.name} (#{service.image})")

    old_digest =
      case Podman.image_digest(service.image) do
        {:ok, d} -> d
        _ -> nil
      end

    case Podman.pull_image(service.image) do
      :ok ->
        new_digest =
          case Podman.image_digest(service.image) do
            {:ok, d} -> d
            _ -> nil
          end

        if new_digest != nil and new_digest != old_digest do
          Logger.info("ImageUpdateWorker: #{service.name} has a new image (#{new_digest}), triggering redeploy")
          # Use a system user ID (nil = system-triggered)
          case Deployments.deploy_service(service.id, nil) do
            {:ok, _} -> :ok
            {:error, reason} ->
              Logger.error("ImageUpdateWorker: failed to queue redeploy for #{service.name}: #{inspect(reason)}")
          end
        else
          Logger.info("ImageUpdateWorker: #{service.name} is up to date")
        end

      {:error, reason} ->
        Logger.warning("ImageUpdateWorker: pull failed for #{service.name}: #{inspect(reason)}")
    end
  end
end
