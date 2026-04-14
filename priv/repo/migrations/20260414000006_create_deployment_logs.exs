defmodule Quadman.Repo.Migrations.CreateDeploymentLogs do
  use Ecto.Migration

  def change do
    create table(:deployment_logs) do
      add :level, :string, null: false, default: "info"
      add :message, :text, null: false
      add :deployment_id, references(:deployments, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:deployment_logs, [:deployment_id])
  end
end
