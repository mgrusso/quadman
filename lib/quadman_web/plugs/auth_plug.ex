defmodule QuadmanWeb.AuthPlug do
  import Plug.Conn
  alias Quadman.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    token = get_session(conn, :user_token)

    case token && Accounts.verify_user_token(token) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      _ ->
        assign(conn, :current_user, nil)
    end
  end
end
