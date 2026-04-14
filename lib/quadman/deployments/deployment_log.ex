defmodule Quadman.Deployments.DeploymentLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "deployment_logs" do
    field :level, :string, default: "info"
    field :message, :string

    belongs_to :deployment, Quadman.Deployments.Deployment

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @valid_levels ~w(info warn error)

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:level, :message, :deployment_id])
    |> validate_required([:message, :deployment_id])
    |> validate_inclusion(:level, @valid_levels)
  end
end
