defmodule Quadman.Stacks do
  import Ecto.Query
  alias Quadman.Repo
  alias Quadman.Stacks.Stack
  alias Quadman.{Services, Deployments, Compose, Systemd, Caddy}
  alias Quadman.Services.{Service, EnvironmentVariable}

  def list_stacks do
    Stack
    |> order_by([s], s.name)
    |> Repo.all()
  end

  def list_stacks_with_services do
    Stack
    |> preload(:services)
    |> order_by([s], s.name)
    |> Repo.all()
  end

  def get_stack!(id), do: Repo.get!(Stack, id)

  def get_stack_with_services!(id) do
    Stack
    |> preload(:services)
    |> Repo.get!(id)
  end

  def create_stack(attrs) do
    %Stack{}
    |> Stack.changeset(attrs)
    |> Repo.insert()
  end

  def update_stack(%Stack{} = stack, attrs) do
    stack
    |> Stack.changeset(attrs)
    |> Repo.update()
  end

  def delete_stack(%Stack{} = stack), do: Repo.delete(stack)

  def delete_stack_with_services(%Stack{} = stack) do
    services =
      Service
      |> where([s], s.stack_id == ^stack.id)
      |> Repo.all()

    needs_reload =
      Enum.reduce(services, false, fn service, reload ->
        if service.unit_name, do: Systemd.stop(service.unit_name)

        if service.quadlet_path && File.exists?(service.quadlet_path) do
          File.rm(service.quadlet_path)
          true
        else
          reload
        end
      end)

    Enum.each(services, fn service ->
      if service.domain, do: Caddy.remove_route(service.domain)
      Services.delete_service(service)
    end)

    if needs_reload, do: Systemd.daemon_reload()

    Repo.delete(stack)
  end

  def change_stack(%Stack{} = stack, attrs \\ %{}) do
    Stack.changeset(stack, attrs)
  end

  @doc """
  Creates a stack and its services from a docker-compose YAML string.
  Returns `{:ok, stack, warnings}` or `{:error, reason}`.
  """
  def create_from_compose(stack_name, yaml, user_id) do
    case Compose.parse(yaml) do
      {:error, reason} ->
        {:error, reason}

      {:ok, service_attrs_list, warnings} ->
        result =
          Repo.transaction(fn ->
            stack =
              %Stack{}
              |> Stack.changeset(%{name: stack_name, compose_yaml: yaml})
              |> Repo.insert!()

            services =
              Enum.map(service_attrs_list, fn attrs ->
                {env_var_attrs, service_attrs} = Map.pop(attrs, :env_vars, [])

                service =
                  %Service{}
                  |> Service.changeset(Map.put(service_attrs, :stack_id, stack.id))
                  |> Repo.insert!()

                Enum.each(env_var_attrs, fn ev ->
                  %EnvironmentVariable{}
                  |> EnvironmentVariable.changeset(Map.put(ev, :service_id, service.id))
                  |> Repo.insert!()
                end)

                service
              end)

            Enum.each(services, fn svc ->
              Deployments.deploy_service(svc.id, user_id)
            end)

            stack
          end)

        case result do
          {:ok, stack} -> {:ok, stack, warnings}
          {:error, %Ecto.Changeset{} = cs} -> {:error, format_changeset_error(cs)}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  @doc """
  Re-parses an updated YAML, diffs against existing services (by compose_service_key),
  creates/updates/removes services accordingly, and enqueues deploys for changed services.
  Returns `{:ok, summary, warnings}` where summary is `%{created: n, updated: n, removed: n}`.
  """
  def update_compose_yaml(%Stack{} = stack, new_yaml, user_id) do
    case Compose.parse(new_yaml) do
      {:error, reason} ->
        {:error, reason}

      {:ok, new_attrs_list, warnings} ->
        existing =
          Service
          |> where([s], s.stack_id == ^stack.id and not is_nil(s.compose_service_key))
          |> Repo.all()

        old_by_key = Map.new(existing, &{&1.compose_service_key, &1})
        new_by_key = Map.new(new_attrs_list, &{&1.compose_service_key, &1})

        to_create = Map.drop(new_by_key, Map.keys(old_by_key))
        to_update = Map.take(new_by_key, Map.keys(old_by_key))
        to_remove = Map.drop(old_by_key, Map.keys(new_by_key))

        result =
          Repo.transaction(fn ->
            stack
            |> Stack.changeset(%{compose_yaml: new_yaml})
            |> Repo.update!()

            # Create new services
            Enum.each(to_create, fn {_key, attrs} ->
              {env_var_attrs, service_attrs} = Map.pop(attrs, :env_vars, [])

              service =
                %Service{}
                |> Service.changeset(Map.put(service_attrs, :stack_id, stack.id))
                |> Repo.insert!()

              Enum.each(env_var_attrs, fn ev ->
                %EnvironmentVariable{}
                |> EnvironmentVariable.changeset(Map.put(ev, :service_id, service.id))
                |> Repo.insert!()
              end)

              Deployments.deploy_service(service.id, user_id)
            end)

            # Update existing services (keep name/id, update image/ports/volumes/restart + env vars)
            Enum.each(to_update, fn {_key, new_attrs} ->
              {env_var_attrs, service_attrs} = Map.pop(new_attrs, :env_vars, [])
              service = old_by_key[new_attrs.compose_service_key]

              update_attrs =
                Map.take(service_attrs, [:image, :port_mappings, :volumes, :restart_policy])

              updated =
                service
                |> Service.changeset(update_attrs)
                |> Repo.update!()

              Repo.delete_all(
                from e in EnvironmentVariable, where: e.service_id == ^updated.id
              )

              Enum.each(env_var_attrs, fn ev ->
                %EnvironmentVariable{}
                |> EnvironmentVariable.changeset(Map.put(ev, :service_id, updated.id))
                |> Repo.insert!()
              end)

              Deployments.deploy_service(updated.id, user_id)
            end)

            %{
              created: map_size(to_create),
              updated: map_size(to_update),
              removed: map_size(to_remove)
            }
          end)

        # Stop and clean up removed services outside the transaction
        Enum.each(to_remove, fn {_key, service} ->
          if service.unit_name, do: Systemd.stop(service.unit_name)
          if service.quadlet_path && File.exists?(service.quadlet_path),
            do: File.rm(service.quadlet_path)
          if service.domain, do: Caddy.remove_route(service.domain)
          Services.delete_service(service)
        end)

        if map_size(to_remove) > 0, do: Systemd.daemon_reload()

        case result do
          {:ok, summary} -> {:ok, summary, warnings}
          {:error, %Ecto.Changeset{} = cs} -> {:error, format_changeset_error(cs)}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  defp format_changeset_error(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  def compute_stack_status(%Stack{services: services}) when is_list(services) do
    statuses = Enum.map(services, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 == "running")) -> "running"
      Enum.all?(statuses, &(&1 == "stopped")) -> "stopped"
      Enum.any?(statuses, &(&1 == "failed")) -> "degraded"
      true -> "degraded"
    end
  end
end
