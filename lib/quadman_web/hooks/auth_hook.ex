defmodule QuadmanWeb.AuthHook do
  import Phoenix.Component
  import Phoenix.LiveView
  alias Quadman.Accounts

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      socket =
        attach_hook(socket, :set_current_path, :handle_params, fn _params, uri, socket ->
          %URI{path: path} = URI.parse(uri)
          {:cont, assign(socket, :current_path, path)}
        end)

      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must log in to access this page.")
        |> redirect(to: "/login")

      {:halt, socket}
    end
  end

  def on_mount(:require_admin, params, session, socket) do
    case on_mount(:require_authenticated_user, params, session, socket) do
      {:cont, socket} ->
        if socket.assigns.current_user.role == "admin" do
          {:cont, socket}
        else
          {:halt, socket |> put_flash(:error, "Admin access required.") |> redirect(to: "/")}
        end

      halt ->
        halt
    end
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  defp mount_current_user(socket, session) do
    case session["user_token"] && Accounts.verify_user_token(session["user_token"]) do
      {:ok, user} -> assign(socket, :current_user, user)
      _ -> assign(socket, :current_user, nil)
    end
  end
end
