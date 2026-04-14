defmodule Quadman.Stacks do
  import Ecto.Query
  alias Quadman.Repo
  alias Quadman.Stacks.Stack

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

  def change_stack(%Stack{} = stack, attrs \\ %{}) do
    Stack.changeset(stack, attrs)
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
