defmodule QuadmanWeb.AuthController do
  use QuadmanWeb, :controller
  alias Quadman.{Accounts, AppSettings}

  def login(conn, _params) do
    conn
    |> put_layout(html: {QuadmanWeb.Layouts, :root})
    |> render(:login, error: nil)
  end

  def login_submit(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        token = Accounts.generate_user_token(user)

        conn
        |> put_session(:user_token, token)
        |> redirect(to: ~p"/")

      {:error, :disabled} ->
        conn
        |> put_layout(html: {QuadmanWeb.Layouts, :root})
        |> render(:login, error: "This account has been disabled.")

      {:error, _} ->
        conn
        |> put_layout(html: {QuadmanWeb.Layouts, :root})
        |> render(:login, error: "Invalid email or password")
    end
  end

  def register(conn, _params) do
    conn
    |> put_layout(html: {QuadmanWeb.Layouts, :root})
    |> render(:register, error: nil, registrations_open: registrations_open?())
  end

  def register_submit(conn, %{
        "email" => email,
        "password" => password,
        "password_confirmation" => confirmation
      }) do
    cond do
      password != confirmation ->
        conn
        |> put_layout(html: {QuadmanWeb.Layouts, :root})
        |> render(:register, error: "Passwords do not match", registrations_open: registrations_open?())

      true ->
        case Accounts.register_user_if_allowed(%{"email" => email, "password" => password}) do
          {:ok, user} ->
            token = Accounts.generate_user_token(user)

            conn
            |> put_session(:user_token, token)
            |> redirect(to: ~p"/")

          {:error, :registrations_disabled} ->
            conn
            |> put_layout(html: {QuadmanWeb.Layouts, :root})
            |> render(:register, error: "Registrations are currently disabled.", registrations_open: false)

          {:error, %Ecto.Changeset{} = changeset} ->
            error =
              changeset
              |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
              |> Enum.map_join(", ", fn {_field, msgs} -> Enum.join(msgs, ", ") end)

            conn
            |> put_layout(html: {QuadmanWeb.Layouts, :root})
            |> render(:register, error: error, registrations_open: registrations_open?())
        end
    end
  end

  def logout(conn, _params) do
    if token = get_session(conn, :user_token) do
      Accounts.revoke_token(token)
    end

    conn
    |> delete_session(:user_token)
    |> redirect(to: ~p"/login")
  end

  defp registrations_open? do
    not Accounts.any_users?() or AppSettings.get("registrations_enabled", "false") == "true"
  end
end
