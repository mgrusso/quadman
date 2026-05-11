defmodule Quadman.Repo.Migrations.AddComposeYamlToStacks do
  use Ecto.Migration

  def change do
    alter table(:stacks) do
      add :compose_yaml, :text, null: true
    end
  end
end
