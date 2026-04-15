defmodule QuadmanWeb.AuthController do
  use QuadmanWeb, :controller
  alias Quadman.Accounts

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

      {:error, _} ->
        conn
        |> put_layout(html: {QuadmanWeb.Layouts, :root})
        |> render(:login, error: "Invalid email or password")
    end
  end

  def logout(conn, _params) do
    conn
    |> delete_session(:user_token)
    |> redirect(to: ~p"/login")
  end
end
