defmodule Quadman.Services.EnvironmentVariable do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "environment_variables" do
    field :key, :string
    field :value, :string, default: ""
    field :is_secret, :boolean, default: false

    belongs_to :service, Quadman.Services.Service

    timestamps(type: :utc_datetime)
  end

  def changeset(env_var, attrs) do
    env_var
    |> cast(attrs, [:key, :value, :is_secret, :service_id])
    |> validate_required([:key, :service_id])
    |> validate_format(:key, ~r/^[A-Z][A-Z0-9_]*$/, message: "must be uppercase letters, digits, and underscores")
    |> unique_constraint([:service_id, :key])
  end
end
