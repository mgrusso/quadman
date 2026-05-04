defmodule QuadmanWeb.SettingsLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Podman, Caddy, CaddyContainer, AppSettings, Updater, Accounts}

  @max_log_lines 500
  @podman_candidates ~w(/usr/bin/podman /bin/podman /usr/local/bin/podman)

  @impl true
  def mount(_params, _session, socket) do
    registrations_enabled = AppSettings.get("registrations_enabled", "false") == "true"
    caddy_tag = CaddyContainer.caddy_tag()

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:password_error, nil)
     |> assign(:password_ok, false)
     |> assign(:current_version, Updater.current_version())
     |> assign(:update_state, :idle)
     |> assign(:latest_release, nil)
     |> assign(:podman_status, check_podman())
     |> assign(:registrations_enabled, registrations_enabled)
     |> assign(:caddy_tag, caddy_tag)
     |> assign(:caddy_tag_input, caddy_tag)
     |> assign(:caddy_log_lines, [])
     |> assign(:caddy_log_buffer, "")
     |> assign(:caddy_log_port, nil)
     |> assign(:caddy_log_streaming, false)
     |> assign(:caddy_image_state, :idle)
     |> load_caddy_status()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Account
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("change_password", %{"current_password" => current, "password" => new_pass}, socket) do
    user = socket.assigns.current_user

    case Accounts.change_password(user, current, new_pass) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:password_ok, true)
         |> assign(:password_error, nil)}

      {:error, :invalid_current_password} ->
        {:noreply, assign(socket, password_error: "Current password is incorrect.", password_ok: false)}

      {:error, changeset} ->
        error =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
          |> Enum.map_join(", ", fn {_field, msgs} -> Enum.join(msgs, ", ") end)

        {:noreply, assign(socket, password_error: error, password_ok: false)}
    end
  end

  # ---------------------------------------------------------------------------
  # Version / Updates
  # ---------------------------------------------------------------------------

  def handle_event("check_updates", _params, socket) do
    with_admin(socket, fn ->
      socket = assign(socket, :update_state, :checking)
      send(self(), :do_check_updates)
      {:noreply, socket}
    end)
  end

  def handle_event("perform_update", _params, socket) do
    with_admin(socket, fn ->
      %{tarball_url: url, sha256_url: sha256_url} = socket.assigns.latest_release
      socket = assign(socket, :update_state, :updating)
      Task.start(fn -> Updater.download_and_apply(url, sha256_url) end)
      {:noreply, socket}
    end)
  end

  @impl true
  def handle_info(:do_check_updates, socket) do
    case Updater.check_latest() do
      {:ok, release} ->
        available = Updater.update_available?(release.version)
        state = if available, do: :update_available, else: :up_to_date

        {:noreply,
         socket
         |> assign(:update_state, state)
         |> assign(:latest_release, release)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:update_state, {:error, reason})
         |> assign(:latest_release, nil)}
    end
  end

  # ---------------------------------------------------------------------------
  # Podman
  # ---------------------------------------------------------------------------

  def handle_event("check_podman", _params, socket) do
    {:noreply, assign(socket, :podman_status, check_podman())}
  end

  # ---------------------------------------------------------------------------
  # Registrations
  # ---------------------------------------------------------------------------

  def handle_event("toggle_registrations", _params, socket) do
    with_admin(socket, fn ->
      new_val = if socket.assigns.registrations_enabled, do: "false", else: "true"
      AppSettings.put("registrations_enabled", new_val)
      {:noreply, assign(socket, :registrations_enabled, new_val == "true")}
    end)
  end

  # ---------------------------------------------------------------------------
  # Caddy container lifecycle
  # ---------------------------------------------------------------------------

  def handle_event("deploy_caddy", _params, socket) do
    with_admin(socket, fn ->
      case CaddyContainer.deploy() do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Caddy container deployed.")
           |> load_caddy_status()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Deploy failed: #{inspect(reason)}")}
      end
    end)
  end

  def handle_event("redeploy_caddy", _params, socket) do
    with_admin(socket, fn ->
      case CaddyContainer.redeploy() do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Caddy redeployed.")
           |> load_caddy_status()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Redeploy failed: #{inspect(reason)}")}
      end
    end)
  end

  def handle_event("undeploy_caddy", _params, socket) do
    with_admin(socket, fn ->
      CaddyContainer.undeploy()

      {:noreply,
       socket
       |> put_flash(:info, "Caddy container removed.")
       |> load_caddy_status()}
    end)
  end

  def handle_event("restart_caddy", _params, socket) do
    with_admin(socket, fn ->
      case CaddyContainer.restart() do
        :ok -> {:noreply, socket |> put_flash(:info, "Caddy restarted.") |> load_caddy_status()}
        {:error, reason} -> {:noreply, put_flash(socket, :error, "Restart failed: #{inspect(reason)}")}
      end
    end)
  end

  def handle_event("check_caddy", _params, socket) do
    {:noreply, load_caddy_status(socket)}
  end

  def handle_event("check_caddy_image", _params, socket) do
    with_admin(socket, fn ->
      pid = self()
      Task.start(fn ->
        result = CaddyContainer.check_for_image_update()
        send(pid, {:caddy_image_checked, result})
      end)
      {:noreply, assign(socket, :caddy_image_state, :checking)}
    end)
  end

  def handle_event("upgrade_caddy_image", _params, socket) do
    with_admin(socket, fn ->
      pid = self()
      Task.start(fn ->
        result = CaddyContainer.upgrade_image()
        send(pid, {:caddy_image_upgraded, result})
      end)
      {:noreply, assign(socket, :caddy_image_state, :upgrading)}
    end)
  end

  def handle_event("set_caddy_tag", %{"tag" => tag}, socket) do
    with_admin(socket, fn ->
      tag = String.trim(tag)

      if tag != "" do
        AppSettings.put("caddy_image_tag", tag)
        {:noreply, assign(socket, :caddy_tag, tag) |> assign(:caddy_tag_input, tag)}
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("caddy_tag_input", %{"value" => val}, socket) do
    {:noreply, assign(socket, :caddy_tag_input, val)}
  end

  # ---------------------------------------------------------------------------
  # Caddy log streaming
  # ---------------------------------------------------------------------------

  def handle_event("start_caddy_logs", _params, socket) do
    with_admin(socket, fn -> {:noreply, start_caddy_log_stream(socket)} end)
  end

  def handle_event("stop_caddy_logs", _params, socket) do
    with_admin(socket, fn -> {:noreply, stop_caddy_log_stream(socket)} end)
  end

  def handle_event("clear_caddy_logs", _params, socket) do
    with_admin(socket, fn -> {:noreply, assign(socket, :caddy_log_lines, [])} end)
  end

  @impl true
  def handle_info({port, {:data, data}}, %{assigns: %{caddy_log_port: port}} = socket) do
    buffer = socket.assigns.caddy_log_buffer <> data
    {complete, new_buffer} = split_buffer(buffer)
    new_lines = Enum.reject(complete, &(&1 == ""))
    lines = (socket.assigns.caddy_log_lines ++ new_lines) |> Enum.take(-@max_log_lines)
    {:noreply, socket |> assign(:caddy_log_lines, lines) |> assign(:caddy_log_buffer, new_buffer)}
  end

  def handle_info({port, {:exit_status, _}}, %{assigns: %{caddy_log_port: port}} = socket) do
    {:noreply,
     socket
     |> assign(:caddy_log_port, nil)
     |> assign(:caddy_log_streaming, false)
     |> assign(:caddy_log_buffer, "")}
  end

  def handle_info({:caddy_image_checked, {:ok, :up_to_date}}, socket) do
    {:noreply, assign(socket, :caddy_image_state, :up_to_date)}
  end

  def handle_info({:caddy_image_checked, {:ok, {:update_available, digest}}}, socket) do
    {:noreply, assign(socket, :caddy_image_state, {:update_available, digest})}
  end

  def handle_info({:caddy_image_checked, {:error, reason}}, socket) do
    {:noreply, assign(socket, :caddy_image_state, {:error, inspect(reason)})}
  end

  def handle_info({:caddy_image_upgraded, {:ok, _image}}, socket) do
    {:noreply, socket |> assign(:caddy_image_state, :up_to_date) |> load_caddy_status()}
  end

  def handle_info({:caddy_image_upgraded, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:caddy_image_state, {:error, inspect(reason)}) |> load_caddy_status()}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    stop_caddy_log_stream(socket)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Log stream helpers
  # ---------------------------------------------------------------------------

  defp start_caddy_log_stream(socket) do
    socket = stop_caddy_log_stream(socket)

    case find_podman() do
      nil ->
        put_flash(socket, :error, "podman not found")

      exe ->
        container_name = "systemd-caddy"

        {_, code} =
          System.cmd(exe, ["inspect", "--type", "container", container_name],
            stderr_to_stdout: true,
            env: caddy_podman_env())

        if code == 0 do
          args = ["logs", "--follow", "--names", "--tail", "200", container_name]
          open_caddy_log_port(socket, exe, args)
        else
          open_caddy_journalctl_stream(socket)
        end
    end
  end

  defp open_caddy_log_port(socket, exe, args) do
    port_opts = [:binary, :stderr_to_stdout, :exit_status, args: args, cd: "/opt/quadman"]

    port =
      try do
        Port.open({:spawn_executable, exe}, port_opts)
      rescue
        _ -> nil
      end

    if is_port(port) do
      socket
      |> assign(:caddy_log_port, port)
      |> assign(:caddy_log_streaming, true)
      |> assign(:caddy_log_buffer, "")
    else
      put_flash(socket, :error, "Could not open Caddy log stream.")
    end
  end

  defp open_caddy_journalctl_stream(socket) do
    exe = System.find_executable("journalctl") || "/usr/bin/journalctl"
    {uid, _} = System.cmd("id", ["-u"])
    uid = String.trim(uid)
    dbus = "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/#{uid}/bus"
    args = ["--user-unit", "caddy.service", "--no-pager", "--follow", "--output", "short"]
    shell_cmd = "#{dbus} #{exe} #{Enum.map_join(args, " ", &shell_escape/1)}"

    port =
      try do
        Port.open({:spawn_executable, "/bin/sh"},
          [:binary, :stderr_to_stdout, :exit_status, args: ["-c", shell_cmd], cd: "/opt/quadman"])
      rescue
        _ -> nil
      end

    if is_port(port) do
      socket
      |> assign(:caddy_log_port, port)
      |> assign(:caddy_log_streaming, true)
      |> assign(:caddy_log_buffer, "")
    else
      put_flash(socket, :error, "No Caddy logs available.")
    end
  end

  defp caddy_podman_env do
    {uid, _} = System.cmd("id", ["-u"])
    [{"HOME", "/opt/quadman"}, {"XDG_RUNTIME_DIR", "/run/user/#{String.trim(uid)}"}]
  end

  defp shell_escape(s), do: "'#{String.replace(s, "'", "'\\''")}'"

  defp stop_caddy_log_stream(%{assigns: %{caddy_log_port: nil}} = socket), do: socket

  defp stop_caddy_log_stream(%{assigns: %{caddy_log_port: port}} = socket) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    socket
    |> assign(:caddy_log_port, nil)
    |> assign(:caddy_log_streaming, false)
    |> assign(:caddy_log_buffer, "")
  end

  defp split_buffer(buffer) do
    case String.split(buffer, "\n") do
      [single] -> {[], single}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp with_admin(socket, fun) do
    if socket.assigns.current_user.role == "admin" do
      fun.()
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  defp find_podman do
    System.find_executable("podman") ||
      Enum.find(@podman_candidates, &File.exists?/1)
  end

  # ---------------------------------------------------------------------------
  # Status helpers
  # ---------------------------------------------------------------------------

  defp load_caddy_status(socket) do
    container_status = CaddyContainer.status()

    api_status =
      if container_status == :running do
        case Caddy.ping() do
          :ok -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end
      else
        :unavailable
      end

    caddy_routes =
      if api_status == :ok do
        case Caddy.list_routes() do
          {:ok, routes} -> routes
          _ -> []
        end
      else
        []
      end

    socket
    |> assign(:caddy_container_status, container_status)
    |> assign(:caddy_api_status, api_status)
    |> assign(:caddy_routes, caddy_routes)
  end

  defp check_podman do
    case Podman.ping() do
      :ok -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-3xl mx-auto">
      <h1 class="text-2xl font-bold text-white mb-6">Settings</h1>

      <%!-- Account --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl mb-6">
        <div class="px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">Account</h2>
          <p class="text-xs text-gray-500 mt-0.5"><%= @current_user.email %></p>
        </div>
        <div class="px-5 py-4">
          <h3 class="text-sm font-medium text-gray-300 mb-3">Change password</h3>
          <%= if @password_ok do %>
            <div class="mb-3 flex items-center gap-2 text-emerald-400 text-sm">
              <span class="w-2 h-2 bg-emerald-400 rounded-full"></span>
              Password updated successfully.
            </div>
          <% end %>
          <%= if @password_error do %>
            <div class="mb-3 text-sm text-red-400"><%= @password_error %></div>
          <% end %>
          <form phx-submit="change_password" class="flex items-end gap-3">
            <div>
              <label class="block text-xs text-gray-500 mb-1">Current password</label>
              <input
                type="password"
                name="current_password"
                required
                autocomplete="current-password"
                class="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-indigo-500"
              />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">New password</label>
              <input
                type="password"
                name="password"
                required
                minlength="8"
                autocomplete="new-password"
                class="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-indigo-500"
              />
            </div>
            <button
              type="submit"
              class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-colors"
            >
              Update
            </button>
          </form>
        </div>
      </div>

      <%!-- Version & updates --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl mb-6">
        <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
          <div>
            <h2 class="font-semibold text-white">Quadman</h2>
            <p class="text-xs text-gray-500 mt-0.5">
              Running version <span class="font-mono text-gray-300">v<%= @current_version %></span>
            </p>
          </div>
          <%= if @update_state not in [:checking, :updating] do %>
            <button phx-click="check_updates" class="text-sm text-indigo-400 hover:text-indigo-300 transition-colors">
              Check for updates
            </button>
          <% else %>
            <span class="text-sm text-gray-500 animate-pulse">
              <%= if @update_state == :checking, do: "Checking…", else: "Updating…" %>
            </span>
          <% end %>
        </div>

        <%= if @update_state != :idle do %>
          <div class="px-5 py-4">
            <%= case @update_state do %>
              <% :up_to_date -> %>
                <div class="flex items-center gap-2 text-emerald-400 text-sm">
                  <span class="w-2 h-2 bg-emerald-400 rounded-full"></span>
                  You're on the latest version.
                </div>
              <% :update_available -> %>
                <div class="space-y-3">
                  <div class="flex items-center justify-between">
                    <div class="text-sm text-white font-medium">
                      Version <span class="font-mono">v<%= @latest_release.version %></span> available
                    </div>
                    <button
                      phx-click="perform_update"
                      data-confirm={"Update to v#{@latest_release.version}? Quadman will restart automatically."}
                      class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-colors"
                    >
                      Update now
                    </button>
                  </div>
                  <%= if @latest_release.notes != "" do %>
                    <div class="text-xs text-gray-400 bg-gray-800 rounded-lg px-3 py-2 font-mono whitespace-pre-wrap leading-relaxed">
                      <%= @latest_release.notes %>
                    </div>
                  <% end %>
                </div>
              <% :updating -> %>
                <div class="text-sm text-gray-400 animate-pulse">
                  Downloading and applying update… The page will reconnect automatically when done.
                </div>
              <% {:error, reason} -> %>
                <div class="flex items-start gap-2 text-red-400 text-sm">
                  <span class="w-2 h-2 bg-red-400 rounded-full mt-1.5 flex-shrink-0"></span>
                  <span>Update check failed: <span class="font-mono text-xs"><%= reason %></span></span>
                </div>
              <% _ -> %>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- System config --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl mb-6">
        <div class="px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">System</h2>
        </div>
        <div class="divide-y divide-gray-800">
          <.config_row label="Podman socket" value={Application.get_env(:quadman, :podman_socket_path, "/run/user/1000/podman/podman.sock")} />
          <.config_row label="Quadlet directory" value={Application.get_env(:quadman, :quadlet_dir, "~/.config/containers/systemd")} />
          <.config_row label="Secrets directory" value={Application.get_env(:quadman, :quadlet_secret_dir, "~/.config/quadman/secrets")} />
          <.config_row label="systemd scope" value={Application.get_env(:quadman, :systemd_scope, "user")} />
        </div>
      </div>

      <%!-- User registration --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl mb-6">
        <div class="flex items-center justify-between px-5 py-4">
          <div>
            <h2 class="font-semibold text-white">User Registration</h2>
            <p class="text-xs text-gray-500 mt-0.5">Allow new users to register at <span class="font-mono">/register</span></p>
          </div>
          <.toggle on={@registrations_enabled} event="toggle_registrations" />
        </div>
      </div>

      <%!-- Podman connectivity --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl mb-6">
        <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">Podman</h2>
          <button phx-click="check_podman" class="text-sm text-indigo-400 hover:text-indigo-300">Re-check</button>
        </div>
        <div class="px-5 py-4">
          <.connectivity_status status={@podman_status} ok_label="Podman socket reachable" />
        </div>
      </div>

      <%!-- Reverse Proxy (Caddy) --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl">
        <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
          <div>
            <h2 class="font-semibold text-white">Reverse Proxy</h2>
            <p class="text-xs text-gray-500 mt-0.5">Caddy container — automatic HTTPS for all services</p>
          </div>
          <div class="flex items-center gap-3">
            <button phx-click="check_caddy" class="text-sm text-indigo-400 hover:text-indigo-300">Re-check</button>
            <.container_status_badge status={@caddy_container_status} />
          </div>
        </div>

        <div class="px-5 py-4 space-y-5">
          <%!-- Image tag --%>
          <div>
            <div class="text-xs text-gray-500 uppercase tracking-wide mb-2">Image tag</div>
            <form phx-submit="set_caddy_tag" class="flex items-center gap-2">
              <input
                type="text"
                name="tag"
                value={@caddy_tag_input}
                placeholder="2"
                class="bg-gray-800 border border-gray-700 text-gray-200 text-sm rounded-lg px-3 py-1.5 font-mono focus:outline-none focus:border-indigo-500 w-40"
              />
              <button
                type="submit"
                class="text-xs border border-gray-700 text-gray-300 hover:border-indigo-500 hover:text-indigo-400 rounded-lg px-3 py-1.5 transition-colors"
              >
                Save
              </button>
              <span class="text-xs text-gray-600">e.g. <span class="font-mono">2</span>, <span class="font-mono">2.9</span>, <span class="font-mono">alpine</span></span>
            </form>
          </div>

          <%!-- Image update check --%>
          <div class="flex items-center gap-3 border-t border-gray-800 pt-4 flex-wrap">
            <div class="text-xs text-gray-500 uppercase tracking-wide flex-shrink-0">Image update</div>
            <%= case @caddy_image_state do %>
              <% :idle -> %>
                <button
                  phx-click="check_caddy_image"
                  class="text-xs border border-gray-700 text-gray-300 hover:border-indigo-500 hover:text-indigo-400 rounded-lg px-3 py-1.5 transition-colors"
                >
                  Check for update
                </button>
              <% :checking -> %>
                <span class="text-xs text-gray-500 animate-pulse">Checking…</span>
              <% :up_to_date -> %>
                <span class="text-xs text-emerald-400">✓ Up to date</span>
                <button phx-click="check_caddy_image" class="text-xs text-gray-500 hover:text-gray-300 transition-colors">Re-check</button>
              <% {:update_available, new_digest} -> %>
                <span class="text-xs text-yellow-400">Update available</span>
                <span class="text-xs font-mono text-gray-500"><%= String.slice(new_digest || "", 0..23) %></span>
                <button
                  phx-click="upgrade_caddy_image"
                  class="text-xs bg-indigo-600 hover:bg-indigo-500 text-white rounded-lg px-3 py-1.5 transition-colors"
                >
                  Upgrade Caddy
                </button>
              <% :upgrading -> %>
                <span class="text-xs text-gray-500 animate-pulse">Pulling image, restarting, syncing routes…</span>
              <% {:error, reason} -> %>
                <span class="text-xs text-red-400"><%= reason %></span>
                <button phx-click="check_caddy_image" class="text-xs text-gray-500 hover:text-gray-300 transition-colors">Retry</button>
            <% end %>
          </div>

          <%!-- Container controls --%>
          <div class="flex items-center gap-3 border-t border-gray-800 pt-4">
            <%= if @caddy_container_status == :not_deployed do %>
              <button
                phx-click="deploy_caddy"
                class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-colors"
              >
                Deploy Caddy
              </button>
            <% else %>
              <button
                phx-click="restart_caddy"
                class="border border-gray-700 text-gray-300 hover:border-indigo-500 hover:text-indigo-400 text-sm rounded-lg px-3 py-1.5 transition-colors"
              >
                Restart
              </button>
              <button
                phx-click="redeploy_caddy"
                data-confirm="Pull latest image and redeploy Caddy? It will be briefly unavailable."
                class="border border-gray-700 text-gray-300 hover:border-indigo-500 hover:text-indigo-400 text-sm rounded-lg px-3 py-1.5 transition-colors"
              >
                Redeploy
              </button>
              <button
                phx-click="undeploy_caddy"
                data-confirm="Stop and remove the Caddy container? Services will become unreachable."
                class="border border-gray-700 text-gray-300 hover:border-red-700 hover:text-red-400 text-sm rounded-lg px-3 py-1.5 transition-colors"
              >
                Undeploy
              </button>
            <% end %>
          </div>

          <%!-- Admin API status --%>
          <div class="border-t border-gray-800 pt-4">
            <.connectivity_status status={@caddy_api_status} ok_label="Caddy Admin API reachable at localhost:2019" />
          </div>

          <%!-- Active routes --%>
          <%= if @caddy_routes != [] do %>
            <div class="border-t border-gray-800 pt-4">
              <div class="text-xs text-gray-500 mb-2 uppercase tracking-wide">Active routes</div>
              <div class="space-y-1">
                <%= for route <- @caddy_routes do %>
                  <% id = Map.get(route, "@id", "") %>
                  <% hosts = get_in(route, ["match", Access.at(0), "host"]) || [] %>
                  <% upstreams = get_in(route, ["handle", Access.at(0), "upstreams"]) || [] %>
                  <div class="flex items-center justify-between bg-gray-800 rounded-lg px-3 py-2 text-xs font-mono">
                    <span class={if String.starts_with?(id, "quadman-"), do: "text-indigo-400", else: "text-gray-400"}>
                      <%= Enum.join(hosts, ", ") %>
                    </span>
                    <span class="text-gray-500">→ <%= Enum.map_join(upstreams, ", ", & &1["dial"]) %></span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Caddy log stream --%>
          <div class="border-t border-gray-800 pt-4">
            <div class="flex items-center justify-between mb-2">
              <div class="text-xs text-gray-500 uppercase tracking-wide">Caddy logs</div>
              <div class="flex items-center gap-2">
                <button
                  phx-click="clear_caddy_logs"
                  class="text-xs text-gray-500 hover:text-gray-300 transition-colors"
                >
                  Clear
                </button>
                <%= if @caddy_log_streaming do %>
                  <button
                    phx-click="stop_caddy_logs"
                    class="text-xs text-red-400 hover:text-red-300 border border-red-900 hover:border-red-700 px-2 py-1 rounded transition-colors"
                  >
                    Stop
                  </button>
                  <div class="flex items-center gap-1">
                    <span class="w-1.5 h-1.5 bg-emerald-400 rounded-full animate-pulse"></span>
                    <span class="text-xs text-emerald-400">Live</span>
                  </div>
                <% else %>
                  <button
                    phx-click="start_caddy_logs"
                    class="text-xs text-indigo-400 hover:text-indigo-300 border border-indigo-800 hover:border-indigo-600 px-2 py-1 rounded transition-colors"
                  >
                    Stream
                  </button>
                <% end %>
              </div>
            </div>
            <div
              id="caddy-log-container"
              phx-hook="LogStream"
              class="bg-gray-950 rounded-lg p-3 font-mono text-xs leading-5 h-48 overflow-y-auto"
            >
              <%= if @caddy_log_lines == [] do %>
                <span class="text-gray-600 italic">Click Stream to see Caddy logs (TLS certificates, requests, errors)…</span>
              <% else %>
                <%= for {line, idx} <- Enum.with_index(@caddy_log_lines) do %>
                  <div id={"cl-#{idx}"} class={caddy_log_class(line)}><%= line %></div>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

  defp caddy_log_class(line) do
    cond do
      String.match?(line, ~r/\b(error|ERROR|fatal|FATAL)\b/) -> "text-red-400 whitespace-pre-wrap break-all"
      String.match?(line, ~r/\b(warn|WARN|warning)\b/) -> "text-yellow-400 whitespace-pre-wrap break-all"
      String.match?(line, ~r/\b(tls|certificate|acme|obtained)\b/i) -> "text-emerald-400 whitespace-pre-wrap break-all"
      true -> "text-gray-300 whitespace-pre-wrap break-all"
    end
  end

  defp toggle(assigns) do
    ~H"""
    <button
      phx-click={@event}
      class={[
        "relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none",
        if(@on, do: "bg-indigo-600", else: "bg-gray-700")
      ]}
    >
      <span class={[
        "inline-block h-4 w-4 transform rounded-full bg-white transition-transform",
        if(@on, do: "translate-x-6", else: "translate-x-1")
      ]} />
    </button>
    """
  end

  defp container_status_badge(assigns) do
    ~H"""
    <span class={[
      "text-xs px-2 py-0.5 rounded-full font-medium",
      case @status do
        :running -> "bg-emerald-900/60 text-emerald-300"
        :not_deployed -> "bg-gray-800 text-gray-500"
        _ -> "bg-yellow-900/60 text-yellow-300"
      end
    ]}>
      <%= case @status do
        :running -> "running"
        :not_deployed -> "not deployed"
        {:stopped, s} -> "stopped (#{s})"
      end %>
    </span>
    """
  end

  defp config_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-5 py-3">
      <span class="text-sm text-gray-400"><%= @label %></span>
      <span class="text-sm text-gray-200 font-mono"><%= @value %></span>
    </div>
    """
  end

  defp connectivity_status(assigns) do
    ~H"""
    <%= case @status do %>
      <% :ok -> %>
        <div class="flex items-center gap-2 text-emerald-400 text-sm">
          <span class="w-2 h-2 bg-emerald-400 rounded-full"></span>
          <%= @ok_label %>
        </div>
      <% :unavailable -> %>
        <div class="text-sm text-gray-500">Container not running</div>
      <% {:error, reason} -> %>
        <div class="flex items-start gap-2 text-red-400 text-sm">
          <span class="w-2 h-2 bg-red-400 rounded-full mt-1.5 flex-shrink-0"></span>
          <div>
            <div>Unreachable</div>
            <div class="text-xs text-gray-500 font-mono mt-1 break-all"><%= reason %></div>
          </div>
        </div>
    <% end %>
    """
  end
end
