defmodule Quadman.Accounts do
  alias Quadman.Repo
  alias Quadman.Accounts.User

  @token_salt "user_auth"
  @token_max_age 14 * 24 * 60 * 60

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  def list_users, do: Repo.all(User)

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def authenticate_user(email, password) do
    user = get_user_by_email(email)

    cond do
      user && User.valid_password?(user, password) -> {:ok, user}
      user -> {:error, :bad_password}
      true -> {:error, :not_found}
    end
  end

  def generate_user_token(user) do
    Phoenix.Token.sign(QuadmanWeb.Endpoint, @token_salt, user.id)
  end

  def verify_user_token(token) do
    case Phoenix.Token.verify(QuadmanWeb.Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, user_id} -> {:ok, get_user!(user_id)}
      {:error, reason} -> {:error, reason}
    end
  end
end
