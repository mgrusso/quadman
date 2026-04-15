defmodule Quadman.Services do
  import Ecto.Query
  alias Quadman.Repo
  alias Quadman.Services.{Service, EnvironmentVariable}

  # --- Services ---

  def list_services do
    Service
    |> order_by([s], s.name)
    |> Repo.all()
  end

  def list_services_with_stack do
    Service
    |> preload(:stack)
    |> order_by([s], s.name)
    |> Repo.all()
  end

  def get_service!(id), do: Repo.get!(Service, id)

  def get_service_with_env!(id) do
    Service
    |> preload(:environment_variables)
    |> Repo.get!(id)
  end

  def get_service_with_env(id) do
    Service
    |> preload(:environment_variables)
    |> Repo.get(id)
  end

  def create_service(attrs) do
    %Service{}
    |> Service.changeset(attrs)
    |> Repo.insert()
  end

  def update_service(%Service{} = service, attrs) do
    service
    |> Service.changeset(attrs)
    |> Repo.update()
  end

  def update_service_status(%Service{} = service, status) do
    service
    |> Service.status_changeset(status)
    |> Repo.update()
  end

  def delete_service(%Service{} = service), do: Repo.delete(service)

  def change_service(%Service{} = service, attrs \\ %{}) do
    Service.changeset(service, attrs)
  end

  # --- Environment Variables ---

  def list_env_vars(service_id) do
    EnvironmentVariable
    |> where([e], e.service_id == ^service_id)
    |> order_by([e], e.key)
    |> Repo.all()
  end

  def get_env_var!(id), do: Repo.get!(EnvironmentVariable, id)

  def create_env_var(attrs) do
    %EnvironmentVariable{}
    |> EnvironmentVariable.changeset(attrs)
    |> Repo.insert()
  end

  def update_env_var(%EnvironmentVariable{} = env_var, attrs) do
    env_var
    |> EnvironmentVariable.changeset(attrs)
    |> Repo.update()
  end

  def delete_env_var(%EnvironmentVariable{} = env_var), do: Repo.delete(env_var)

  def upsert_env_vars(service_id, vars) when is_list(vars) do
    Repo.transaction(fn ->
      Repo.delete_all(from e in EnvironmentVariable, where: e.service_id == ^service_id)

      Enum.each(vars, fn var ->
        %EnvironmentVariable{}
        |> EnvironmentVariable.changeset(Map.put(var, :service_id, service_id))
        |> Repo.insert!()
      end)
    end)
  end

  # --- Status refresh ---

  def refresh_service_statuses(unit_statuses) when is_map(unit_statuses) do
    services = list_services()

    Enum.each(services, fn service ->
      if service.unit_name do
        status = Map.get(unit_statuses, service.unit_name, "unknown")
        mapped = map_systemd_status(status)

        if mapped != service.status do
          update_service_status(service, mapped)
        end
      end
    end)
  end

  defp map_systemd_status("active"), do: "running"
  defp map_systemd_status("activating"), do: "running"
  defp map_systemd_status("failed"), do: "failed"
  defp map_systemd_status("inactive"), do: "stopped"
  defp map_systemd_status(_), do: "unknown"
end
