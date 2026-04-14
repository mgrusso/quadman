defmodule Quadman.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :image_digest, :string
      add :status, :string, null: false, default: "pending"
      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all), null: false
      add :triggered_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:deployments, [:service_id])
    create index(:deployments, [:triggered_by_id])
  end
end
