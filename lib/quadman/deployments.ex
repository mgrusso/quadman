defmodule Quadman.Deployments do
  import Ecto.Query
  alias Quadman.Repo
  alias Quadman.Deployments.{Deployment, DeploymentLog}
  alias Quadman.Workers.DeployWorker

  def list_deployments(limit \\ 20) do
    Deployment
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> preload([:service, :triggered_by])
    |> Repo.all()
  end

  def list_deployments_for_service(service_id, limit \\ 10) do
    Deployment
    |> where([d], d.service_id == ^service_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> preload([:triggered_by])
    |> Repo.all()
  end

  def get_deployment!(id), do: Repo.get!(Deployment, id)

  def get_deployment_with_logs!(id) do
    Deployment
    |> preload([:service, :triggered_by, :logs])
    |> Repo.get!(id)
  end

  def create_deployment(attrs) do
    %Deployment{}
    |> Deployment.changeset(attrs)
    |> Repo.insert()
  end

  def update_deployment_status(%Deployment{} = deployment, status, opts \\ []) do
    deployment
    |> Deployment.status_changeset(status, opts)
    |> Repo.update()
  end

  def append_log(deployment_id, message, level \\ "info") do
    %DeploymentLog{}
    |> DeploymentLog.changeset(%{deployment_id: deployment_id, message: message, level: level})
    |> Repo.insert()

    Phoenix.PubSub.broadcast(
      Quadman.PubSub,
      "deployment:#{deployment_id}",
      {:log, %{level: level, message: message}}
    )
  end

  def list_logs(deployment_id) do
    DeploymentLog
    |> where([l], l.deployment_id == ^deployment_id)
    |> order_by([l], l.id)
    |> Repo.all()
  end

  @doc "Deletes deployments for a service beyond the most recent `keep` records (cascade-deletes their logs)."
  def trim_old_deployments(service_id, keep \\ 3) do
    ids_to_keep =
      Deployment
      |> where([d], d.service_id == ^service_id)
      |> order_by([d], desc: d.inserted_at)
      |> limit(^keep)
      |> select([d], d.id)
      |> Repo.all()

    if ids_to_keep != [] do
      Deployment
      |> where([d], d.service_id == ^service_id and d.id not in ^ids_to_keep)
      |> Repo.delete_all()
    end

    :ok
  end

  @doc """
  Creates a deployment record and enqueues the Oban deploy job.
  Returns `{:ok, deployment}` or `{:error, reason}`.
  """
  def deploy_service(service_id, user_id) do
    Repo.transaction(fn ->
      deployment =
        %Deployment{}
        |> Deployment.changeset(%{service_id: service_id, triggered_by_id: user_id, status: "pending"})
        |> Repo.insert!()

      %{deployment_id: deployment.id}
      |> DeployWorker.new(queue: :deployments)
      |> Oban.insert!()

      deployment
    end)
  end
end
