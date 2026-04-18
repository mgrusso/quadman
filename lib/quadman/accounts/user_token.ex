defmodule Quadman.Accounts.UserToken do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_tokens" do
    field :token_hash, :string
    belongs_to :user, Quadman.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Returns the SHA-256 hex digest of a raw token string."
  def hash(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
