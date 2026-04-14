defmodule Quadman.Repo.Migrations.CreateEnvironmentVariables do
  use Ecto.Migration

  def change do
    create table(:environment_variables, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value, :string, null: false, default: ""
      add :is_secret, :boolean, null: false, default: false
      add :service_id, references(:services, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:environment_variables, [:service_id])
    create unique_index(:environment_variables, [:service_id, :key])
  end
end
