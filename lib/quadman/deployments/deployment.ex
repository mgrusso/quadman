defmodule Quadman.Deployments.Deployment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "deployments" do
    field :image_digest, :string
    field :status, :string, default: "pending"

    belongs_to :service, Quadman.Services.Service
    belongs_to :triggered_by, Quadman.Accounts.User
    has_many :logs, Quadman.Deployments.DeploymentLog

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending running succeeded failed)

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:image_digest, :status, :service_id, :triggered_by_id])
    |> validate_required([:service_id])
    |> validate_inclusion(:status, @valid_statuses)
  end

  def status_changeset(deployment, status, opts \\ []) do
    attrs = %{status: status}
    attrs = if digest = opts[:image_digest], do: Map.put(attrs, :image_digest, digest), else: attrs

    deployment
    |> cast(attrs, [:status, :image_digest])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
