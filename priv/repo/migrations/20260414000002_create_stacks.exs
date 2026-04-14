defmodule Quadman.Repo.Migrations.CreateStacks do
  use Ecto.Migration

  def change do
    create table(:stacks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :quadlet_type, :string, null: false, default: "multi_container"
      add :status, :string, null: false, default: "stopped"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stacks, [:name])
  end
end
