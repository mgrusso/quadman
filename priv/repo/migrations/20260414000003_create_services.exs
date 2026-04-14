defmodule Quadman.Repo.Migrations.CreateServices do
  use Ecto.Migration

  def change do
    create table(:services, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :image, :string, null: false
      add :port_mappings, :text, default: "[]"
      add :volumes, :text, default: "[]"
      add :resource_cpu, :string
      add :resource_mem, :string
      add :restart_policy, :string, null: false, default: "on-failure"
      add :quadlet_path, :string
      add :unit_name, :string
      add :status, :string, null: false, default: "stopped"
      add :stack_id, references(:stacks, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:services, [:name])
    create index(:services, [:stack_id])
  end
end
