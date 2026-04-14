defmodule Quadman.Repo.Migrations.AddDomainToServices do
  use Ecto.Migration

  def change do
    alter table(:services) do
      add :domain, :string
    end

    create unique_index(:services, [:domain])
  end
end
