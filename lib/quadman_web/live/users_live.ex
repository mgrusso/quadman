defmodule QuadmanWeb.UsersLive do
  use QuadmanWeb, :live_view

  alias Quadman.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Users")
     |> assign(:show_create, false)
     |> assign(:create_error, nil)
     |> assign(:set_password_user_id, nil)
     |> assign(:set_password_error, nil)
     |> load_users()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("show_create", _, socket) do
    {:noreply, assign(socket, show_create: true, create_error: nil)}
  end

  def handle_event("hide_create", _, socket) do
    {:noreply, assign(socket, show_create: false, create_error: nil)}
  end

  def handle_event("create_user", %{"email" => email, "password" => password, "role" => role}, socket) do
    case Accounts.create_user(%{"email" => email, "password" => password, "role" => role}) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(show_create: false, create_error: nil)
         |> load_users()
         |> put_flash(:info, "User created.")}

      {:error, changeset} ->
        error =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
          |> Enum.map_join(", ", fn {_field, msgs} -> Enum.join(msgs, ", ") end)

        {:noreply, assign(socket, create_error: error)}
    end
  end

  def handle_event("show_set_password", %{"id" => id}, socket) do
    {:noreply, assign(socket, set_password_user_id: id, set_password_error: nil, show_create: false)}
  end

  def handle_event("hide_set_password", _, socket) do
    {:noreply, assign(socket, set_password_user_id: nil, set_password_error: nil)}
  end

  def handle_event("set_password", %{"user_id" => id, "password" => password}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.set_password(user, password) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(set_password_user_id: nil, set_password_error: nil)
         |> put_flash(:info, "Password updated for #{user.email}.")}

      {:error, changeset} ->
        error =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
          |> Enum.map_join(", ", fn {_field, msgs} -> Enum.join(msgs, ", ") end)

        {:noreply, assign(socket, :set_password_error, error)}
    end
  end

  def handle_event("toggle_disabled", %{"id" => id}, socket) do
    current_user = socket.assigns.current_user

    if id == current_user.id do
      {:noreply, put_flash(socket, :error, "You cannot disable your own account.")}
    else
      user = Accounts.get_user!(id)
      {:ok, _} = Accounts.set_user_disabled(user, !user.disabled)
      {:noreply, load_users(socket)}
    end
  end

  def handle_event("toggle_admin", %{"id" => id}, socket) do
    current_user = socket.assigns.current_user
    user = Accounts.get_user!(id)

    cond do
      id == current_user.id ->
        {:noreply, put_flash(socket, :error, "You cannot change your own role.")}

      user.role == "admin" && Accounts.admin_count() <= 1 ->
        {:noreply, put_flash(socket, :error, "Cannot demote the last administrator.")}

      true ->
        new_role = if user.role == "admin", do: "user", else: "admin"
        {:ok, _} = Accounts.set_user_role(user, new_role)
        {:noreply, load_users(socket)}
    end
  end

  def handle_event("delete_user", %{"id" => id}, socket) do
    current_user = socket.assigns.current_user
    user = Accounts.get_user!(id)

    cond do
      id == current_user.id ->
        {:noreply, put_flash(socket, :error, "You cannot delete your own account.")}

      user.role == "admin" && Accounts.admin_count() <= 1 ->
        {:noreply, put_flash(socket, :error, "Cannot delete the last administrator.")}

      true ->
        {:ok, _} = Accounts.delete_user(user)

        {:noreply,
         socket
         |> load_users()
         |> put_flash(:info, "User deleted.")}
    end
  end

  defp load_users(socket) do
    assign(socket, :users, Accounts.list_users())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-4xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-white">Users</h1>
        <button
          phx-click="show_create"
          class="flex items-center gap-2 bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-colors"
        >
          <span class="hero-plus w-4 h-4"></span>
          New user
        </button>
      </div>

      <%!-- Create user form --%>
      <%= if @show_create do %>
        <div class="bg-gray-900 border border-gray-800 rounded-xl p-6 mb-6">
          <h2 class="font-semibold text-white mb-4">Create user</h2>

          <%= if @create_error do %>
            <div class="mb-4 p-3 bg-red-900/50 border border-red-700 rounded-lg text-red-300 text-sm">
              <%= @create_error %>
            </div>
          <% end %>

          <form phx-submit="create_user" class="space-y-4">
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-300 mb-1">Email</label>
                <input
                  type="email"
                  name="email"
                  required
                  class="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white text-sm placeholder-gray-500 focus:outline-none focus:border-indigo-500"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-300 mb-1">Password</label>
                <input
                  type="password"
                  name="password"
                  required
                  class="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white text-sm placeholder-gray-500 focus:outline-none focus:border-indigo-500"
                />
              </div>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">Role</label>
              <select
                name="role"
                class="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:outline-none focus:border-indigo-500"
              >
                <option value="user">User</option>
                <option value="admin">Admin</option>
              </select>
            </div>

            <div class="flex items-center gap-3">
              <button
                type="submit"
                class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-colors"
              >
                Create
              </button>
              <button
                type="button"
                phx-click="hide_create"
                class="text-sm text-gray-400 hover:text-white transition-colors"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      <% end %>

      <%!-- Set password panel --%>
      <%= if @set_password_user_id do %>
        <% target = Enum.find(@users, &(&1.id == @set_password_user_id)) %>
        <div class="bg-gray-900 border border-gray-800 rounded-xl p-6 mb-6">
          <h2 class="font-semibold text-white mb-1">Set password</h2>
          <p class="text-sm text-gray-400 mb-4"><%= target && target.email %></p>

          <%= if @set_password_error do %>
            <div class="mb-4 p-3 bg-red-900/50 border border-red-700 rounded-lg text-red-300 text-sm">
              <%= @set_password_error %>
            </div>
          <% end %>

          <form phx-submit="set_password" class="flex items-end gap-3">
            <input type="hidden" name="user_id" value={@set_password_user_id} />
            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">New password</label>
              <input
                type="password"
                name="password"
                required
                minlength="8"
                autocomplete="new-password"
                class="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white text-sm placeholder-gray-500 focus:outline-none focus:border-indigo-500"
              />
            </div>
            <button
              type="submit"
              class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-colors"
            >
              Set password
            </button>
            <button
              type="button"
              phx-click="hide_set_password"
              class="text-sm text-gray-400 hover:text-white transition-colors"
            >
              Cancel
            </button>
          </form>
        </div>
      <% end %>

      <%!-- Users table --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-gray-500 border-b border-gray-800">
              <th class="px-5 py-3 font-medium">Email</th>
              <th class="px-5 py-3 font-medium">Role</th>
              <th class="px-5 py-3 font-medium">Status</th>
              <th class="px-5 py-3 font-medium">Joined</th>
              <th class="px-5 py-3 font-medium"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800">
            <%= for user <- @users do %>
              <% is_self = user.id == @current_user.id %>
              <tr class="hover:bg-gray-800/50 transition-colors">
                <td class="px-5 py-3 text-white">
                  <%= user.email %>
                  <%= if is_self do %>
                    <span class="ml-2 text-xs text-gray-500">(you)</span>
                  <% end %>
                </td>
                <td class="px-5 py-3">
                  <span class={[
                    "text-xs px-2 py-0.5 rounded-full font-medium",
                    if(user.role == "admin",
                      do: "bg-indigo-900/60 text-indigo-300",
                      else: "bg-gray-800 text-gray-400")
                  ]}>
                    <%= user.role %>
                  </span>
                </td>
                <td class="px-5 py-3">
                  <span class={[
                    "text-xs px-2 py-0.5 rounded-full font-medium",
                    if(user.disabled,
                      do: "bg-red-900/60 text-red-400",
                      else: "bg-emerald-900/60 text-emerald-400")
                  ]}>
                    <%= if user.disabled, do: "disabled", else: "active" %>
                  </span>
                </td>
                <td class="px-5 py-3 text-gray-500 text-xs">
                  <%= Calendar.strftime(user.inserted_at, "%Y-%m-%d") %>
                </td>
                <td class="px-5 py-3">
                  <div class="flex items-center justify-end gap-2">
                    <button
                      phx-click="show_set_password"
                      phx-value-id={user.id}
                      title="Set password"
                      class="text-xs px-2 py-1 rounded border border-gray-700 text-gray-400 hover:border-indigo-500 hover:text-indigo-400 transition-colors"
                    >
                      Set pwd
                    </button>
                    <button
                      phx-click="toggle_admin"
                      phx-value-id={user.id}
                      disabled={is_self}
                      title={if user.role == "admin", do: "Demote to user", else: "Promote to admin"}
                      class={[
                        "text-xs px-2 py-1 rounded border transition-colors",
                        if(is_self,
                          do: "border-gray-700 text-gray-600 cursor-not-allowed",
                          else: "border-gray-700 text-gray-400 hover:border-indigo-500 hover:text-indigo-400")
                      ]}
                    >
                      <%= if user.role == "admin", do: "Demote", else: "Promote" %>
                    </button>
                    <button
                      phx-click="toggle_disabled"
                      phx-value-id={user.id}
                      disabled={is_self}
                      title={if user.disabled, do: "Enable account", else: "Disable account"}
                      class={[
                        "text-xs px-2 py-1 rounded border transition-colors",
                        if(is_self,
                          do: "border-gray-700 text-gray-600 cursor-not-allowed",
                          else: "border-gray-700 text-gray-400 hover:border-yellow-500 hover:text-yellow-400")
                      ]}
                    >
                      <%= if user.disabled, do: "Enable", else: "Disable" %>
                    </button>
                    <button
                      phx-click="delete_user"
                      phx-value-id={user.id}
                      disabled={is_self}
                      data-confirm="Delete this user? This cannot be undone."
                      title="Delete user"
                      class={[
                        "text-xs px-2 py-1 rounded border transition-colors",
                        if(is_self,
                          do: "border-gray-700 text-gray-600 cursor-not-allowed",
                          else: "border-gray-700 text-gray-400 hover:border-red-500 hover:text-red-400")
                      ]}
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
