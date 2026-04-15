defmodule Quadman.Repo.Migrations.AddAutoUpdateToServices do
  use Ecto.Migration

  def change do
    alter table(:services) do
      add :auto_update, :boolean, default: false, null: false
    end
  end
end
