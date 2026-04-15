defmodule Quadman.Repo.Migrations.AddDisabledToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :disabled, :boolean, default: false, null: false
    end
  end
end
