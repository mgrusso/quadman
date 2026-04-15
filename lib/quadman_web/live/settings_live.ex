defmodule QuadmanWeb.SettingsLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Podman, Caddy, CaddyContainer, AppSettings}

  @impl true
  def mount(_params, _session, socket) do
    registrations_enabled = AppSettings.get("registrations_enabled", "false") == "true"
    caddy_enabled = AppSettings.get("caddy_enabled", "false") == "true"

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:podman_status, check_podman())
     |> assign(:registrations_enabled, registrations_enabled)
     |> assign(:caddy_enabled, caddy_enabled)
     |> load_caddy_status()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # --- Podman ---

  @impl true
  def handle_event("check_podman", _params, socket) do
    {:noreply, assign(socket, :podman_status, check_podman())}
  end

  # --- Registrations ---

  def handle_event("toggle_registrations", _params, socket) do
    new_val = if socket.assigns.registrations_enabled, do: "false", else: "true"
    AppSettings.put("registrations_enabled", new_val)
    {:noreply, assign(socket, :registrations_enabled, new_val == "true")}
  end

  # --- Caddy route management toggle ---

  def handle_event("toggle_caddy_enabled", _params, socket) do
    new_val = if socket.assigns.caddy_enabled, do: "false", else: "true"
    AppSettings.put("caddy_enabled", new_val)
    {:noreply, assign(socket, :caddy_enabled, new_val == "true")}
  end

  # --- Caddy container lifecycle ---

  def handle_event("deploy_caddy", _params, socket) do
    case CaddyContainer.deploy() do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Caddy container deployed.")
         |> load_caddy_status()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Deploy failed: #{inspect(reason)}")}
    end
  end

  def handle_event("undeploy_caddy", _params, socket) do
    CaddyContainer.undeploy()

    {:noreply,
     socket
     |> put_flash(:info, "Caddy container removed.")
     |> load_caddy_status()}
  end

  def handle_event("restart_caddy", _params, socket) do
    case CaddyContainer.restart() do
      :ok -> {:noreply, socket |> put_flash(:info, "Caddy restarted.") |> load_caddy_status()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Restart failed: #{inspect(reason)}")}
    end
  end

  def handle_event("check_caddy", _params, socket) do
    {:noreply, load_caddy_status(socket)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
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

      <%!-- Caddy reverse proxy --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl">
        <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
          <div>
            <h2 class="font-semibold text-white">Caddy reverse proxy</h2>
            <p class="text-xs text-gray-500 mt-0.5">Runs as a Podman container with host networking</p>
          </div>
          <div class="flex items-center gap-3">
            <button phx-click="check_caddy" class="text-sm text-indigo-400 hover:text-indigo-300">Re-check</button>
            <.container_status_badge status={@caddy_container_status} />
          </div>
        </div>

        <div class="px-5 py-4 space-y-4">
          <%!-- Container controls --%>
          <div class="flex items-center gap-3">
            <%= if @caddy_container_status == :not_deployed do %>
              <button
                phx-click="deploy_caddy"
                class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium rounded-lg px-4 py-2 transition-colors"
              >
                Deploy Caddy container
              </button>
            <% else %>
              <button
                phx-click="restart_caddy"
                class="border border-gray-700 text-gray-300 hover:border-indigo-500 hover:text-indigo-400 text-sm rounded-lg px-3 py-1.5 transition-colors"
              >
                Restart
              </button>
              <button
                phx-click="undeploy_caddy"
                data-confirm="Stop and remove the Caddy container?"
                class="border border-gray-700 text-gray-300 hover:border-red-500 hover:text-red-400 text-sm rounded-lg px-3 py-1.5 transition-colors"
              >
                Undeploy
              </button>
            <% end %>
          </div>

          <%!-- Route management toggle --%>
          <%= if @caddy_container_status != :not_deployed do %>
            <div class="flex items-center justify-between py-3 border-t border-gray-800">
              <div>
                <div class="text-sm text-white">Route management</div>
                <div class="text-xs text-gray-500 mt-0.5">Automatically register service domains in Caddy on deploy</div>
              </div>
              <.toggle on={@caddy_enabled} event="toggle_caddy_enabled" />
            </div>

            <%!-- API connectivity --%>
            <div class="border-t border-gray-800 pt-3">
              <.connectivity_status status={@caddy_api_status} ok_label="Caddy Admin API reachable at localhost:2019" />
            </div>

            <%!-- Active routes --%>
            <%= if @caddy_routes != [] do %>
              <div class="border-t border-gray-800 pt-3">
                <div class="text-xs text-gray-500 mb-2 uppercase tracking-wide">Active routes managed by Quadman</div>
                <div class="space-y-1">
                  <%= for route <- @caddy_routes do %>
                    <% id = Map.get(route, "@id", "") %>
                    <%= if String.starts_with?(id, "quadman-") do %>
                      <% hosts = get_in(route, ["match", Access.at(0), "host"]) || [] %>
                      <% upstreams = get_in(route, ["handle", Access.at(0), "upstreams"]) || [] %>
                      <div class="flex items-center justify-between bg-gray-800 rounded-lg px-3 py-2 text-xs font-mono">
                        <span class="text-indigo-400"><%= Enum.join(hosts, ", ") %></span>
                        <span class="text-gray-400">→ <%= Enum.map_join(upstreams, ", ", & &1["dial"]) %></span>
                      </div>
                    <% end %>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% else %>
            <p class="text-sm text-gray-500">
              Deploy the Caddy container to enable automatic HTTPS routing for your services.
              Requires <span class="font-mono text-gray-300">net.ipv4.ip_unprivileged_port_start=80</span> on the host (set automatically by the install script).
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Components
  # ---------------------------------------------------------------------------

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
