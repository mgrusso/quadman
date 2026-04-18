defmodule Quadman.Accounts do
  import Ecto.Query
  alias Quadman.Repo
  alias Quadman.Accounts.{User, UserToken}

  @token_salt "user_auth"
  @token_max_age 14 * 24 * 60 * 60

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  def list_users do
    User |> order_by([u], u.inserted_at) |> Repo.all()
  end

  def any_users? do
    Repo.exists?(User)
  end

  def admin_count do
    Repo.aggregate(from(u in User, where: u.role == "admin" and not u.disabled), :count)
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def register_user_if_allowed(attrs) do
    cond do
      not any_users?() ->
        register_user(Map.put(attrs, "role", "admin"))

      Quadman.AppSettings.get("registrations_enabled", "false") == "true" ->
        register_user(attrs)

      true ->
        {:error, :registrations_disabled}
    end
  end

  def set_user_role(%User{} = user, role) do
    user
    |> User.admin_changeset(%{role: role})
    |> Repo.update()
  end

  def set_user_disabled(%User{} = user, disabled) do
    user
    |> User.admin_changeset(%{disabled: disabled})
    |> Repo.update()
  end

  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  def change_password(%User{} = user, current_password, new_password) do
    if User.valid_password?(user, current_password) do
      case user |> User.password_changeset(%{password: new_password}) |> Repo.update() do
        {:ok, updated} ->
          revoke_all_tokens_for_user(user.id)
          {:ok, updated}

        err ->
          err
      end
    else
      {:error, :invalid_current_password}
    end
  end

  def set_password(%User{} = user, new_password) do
    case user |> User.password_changeset(%{password: new_password}) |> Repo.update() do
      {:ok, updated} ->
        revoke_all_tokens_for_user(user.id)
        {:ok, updated}

      err ->
        err
    end
  end

  def authenticate_user(email, password) do
    user = get_user_by_email(email)

    cond do
      user && user.disabled -> {:error, :disabled}
      user && User.valid_password?(user, password) -> {:ok, user}
      user -> {:error, :bad_password}
      true -> {:error, :not_found}
    end
  end

  def generate_user_token(user) do
    token = Phoenix.Token.sign(QuadmanWeb.Endpoint, @token_salt, user.id)

    Repo.insert!(%UserToken{
      user_id: user.id,
      token_hash: UserToken.hash(token)
    })

    token
  end

  def verify_user_token(token) do
    with {:ok, user_id} <-
           Phoenix.Token.verify(QuadmanWeb.Endpoint, @token_salt, token, max_age: @token_max_age),
         hash = UserToken.hash(token),
         %UserToken{} <- Repo.get_by(UserToken, token_hash: hash, user_id: user_id) do
      user = get_user!(user_id)
      if user.disabled, do: {:error, :disabled}, else: {:ok, user}
    else
      nil -> {:error, :revoked}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke_token(token) when is_binary(token) do
    hash = UserToken.hash(token)
    Repo.delete_all(from t in UserToken, where: t.token_hash == ^hash)
    :ok
  end

  def revoke_all_tokens_for_user(user_id) do
    Repo.delete_all(from t in UserToken, where: t.user_id == ^user_id)
    :ok
  end
end
