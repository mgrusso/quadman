defmodule Quadman.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :hashed_password, :string
    field :password, :string, virtual: true
    field :role, :string, default: "admin"
    field :disabled, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :role])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> validate_length(:password, min: 8, max: 72)
    |> unique_constraint(:email)
    |> put_hashed_password()
  end

  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:role, :disabled])
    |> validate_inclusion(:role, ["admin", "user"])
  end

  defp put_hashed_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :hashed_password, Bcrypt.hash_pwd_salt(password))
    end
  end

  def valid_password?(%__MODULE__{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
