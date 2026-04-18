defmodule Quadman.Repo.Migrations.CreateUserTokens do
  use Ecto.Migration

  def change do
    create table(:user_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:token_hash])
  end
end
