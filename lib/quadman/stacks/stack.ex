defmodule Quadman.Stacks.Stack do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stacks" do
    field :name, :string
    field :quadlet_type, :string, default: "multi_container"
    field :status, :string, default: "stopped"

    has_many :services, Quadman.Services.Service

    timestamps(type: :utc_datetime)
  end

  @valid_types ~w(pod multi_container)
  @valid_statuses ~w(running stopped degraded)

  def changeset(stack, attrs) do
    stack
    |> cast(attrs, [:name, :quadlet_type, :status])
    |> validate_required([:name])
    |> validate_inclusion(:quadlet_type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/, message: "must be lowercase alphanumeric, dashes, or underscores")
    |> unique_constraint(:name)
  end
end
