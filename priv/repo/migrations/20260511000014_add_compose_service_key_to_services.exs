defmodule Quadman.Repo.Migrations.AddComposeServiceKeyToServices do
  use Ecto.Migration

  def change do
    alter table(:services) do
      add :compose_service_key, :string, null: true
    end
  end
end
