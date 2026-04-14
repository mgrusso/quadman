defmodule QuadmanWeb.SettingsLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Podman, Caddy}

  @impl true
  def mount(_params, _session, socket) do
    caddy_enabled = Application.get_env(:quadman, :caddy_enabled, false)

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:podman_status, check_podman())
     |> assign(:caddy_enabled, caddy_enabled)
     |> assign(:caddy_status, if(caddy_enabled, do: check_caddy(), else: :disabled))
     |> assign(:caddy_routes, if(caddy_enabled, do: load_caddy_routes(), else: []))}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("check_podman", _params, socket) do
    {:noreply, assign(socket, :podman_status, check_podman())}
  end

  def handle_event("check_caddy", _params, socket) do
    {:noreply,
     socket
     |> assign(:caddy_status, check_caddy())
     |> assign(:caddy_routes, load_caddy_routes())}
  end

  defp check_podman do
    case Podman.ping() do
      :ok -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp check_caddy do
    case Caddy.ping() do
      :ok -> :ok
      {:error, :disabled} -> :disabled
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp load_caddy_routes do
    case Caddy.list_routes() do
      {:ok, routes} -> routes
      _ -> []
    end
  end

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

      <%!-- Podman connectivity --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl mb-6">
        <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">Podman</h2>
          <button phx-click="check_podman" class="text-sm text-indigo-400 hover:text-indigo-300">
            Re-check
          </button>
        </div>
        <div class="px-5 py-4">
          <.connectivity_status status={@podman_status} ok_label="Podman socket reachable" />
        </div>
      </div>

      <%!-- Caddy --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl">
        <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
          <div>
            <h2 class="font-semibold text-white">Caddy reverse proxy</h2>
            <p class="text-xs text-gray-500 mt-0.5">
              Admin API:
              <span class="font-mono"><%= Application.get_env(:quadman, :caddy_admin_url, "http://localhost:2019") %></span>
            </p>
          </div>
          <div class="flex items-center gap-3">
            <%= if @caddy_enabled do %>
              <button phx-click="check_caddy" class="text-sm text-indigo-400 hover:text-indigo-300">
                Re-check
              </button>
            <% end %>
            <span class={[
              "text-xs px-2 py-0.5 rounded-full font-medium",
              if(@caddy_enabled, do: "bg-emerald-900/60 text-emerald-300", else: "bg-gray-800 text-gray-500")
            ]}>
              <%= if @caddy_enabled, do: "enabled", else: "disabled" %>
            </span>
          </div>
        </div>

        <div class="px-5 py-4">
          <%= if @caddy_enabled do %>
            <.connectivity_status status={@caddy_status} ok_label="Caddy Admin API reachable" />

            <%= if @caddy_routes != [] do %>
              <div class="mt-4">
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

            <div class="mt-4 p-3 bg-gray-800/50 rounded-lg text-xs text-gray-500">
              Enable via <span class="font-mono text-gray-300">CADDY_ENABLED=true</span> in <span class="font-mono text-gray-300">/etc/quadman/env</span>.
              Set a domain on any service and it will be registered on next deploy.
            </div>
          <% else %>
            <div class="text-sm text-gray-500">
              Caddy integration is disabled.
              Set <span class="font-mono text-gray-300">CADDY_ENABLED=true</span> to enable automatic HTTPS routing for your services.
            </div>
          <% end %>
        </div>
      </div>
    </div>
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
      <% :disabled -> %>
        <div class="text-sm text-gray-500">Disabled</div>
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
