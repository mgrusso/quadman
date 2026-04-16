defmodule QuadmanWeb.VolumesLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Podman, Services}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Volumes")
     |> load_volumes()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete_volume", %{"name" => name}, socket) do
    case Podman.delete_volume(name) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Volume \"#{name}\" deleted.")
         |> load_volumes()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete \"#{name}\": #{reason}")}
    end
  end

  def handle_event("delete_unbound", _params, socket) do
    unbound = Enum.filter(socket.assigns.volumes, &is_nil(&1.bound_to))

    {deleted, failed} =
      unbound
      |> Enum.map(fn v -> {v.name, Podman.delete_volume(v.name)} end)
      |> Enum.split_with(fn {_, r} -> r == :ok end)

    socket = load_volumes(socket)

    socket =
      cond do
        failed != [] ->
          names = Enum.map_join(failed, ", ", &elem(&1, 0))
          put_flash(socket, :error, "Failed to delete: #{names}")

        deleted == [] ->
          put_flash(socket, :info, "No unbound volumes to delete.")

        true ->
          put_flash(socket, :info, "Deleted #{length(deleted)} unbound volume(s).")
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp load_volumes(socket) do
    service_bindings = build_service_bindings()

    volumes =
      case Podman.list_volumes() do
        {:ok, vols} ->
          Enum.map(vols, fn v ->
            name = v["Name"]

            %{
              name: name,
              created_at: v["CreatedAt"],
              driver: v["Driver"],
              mountpoint: v["Mountpoint"],
              bound_to: Map.get(service_bindings, name)
            }
          end)
          |> Enum.sort_by(& &1.name)

        {:error, _} ->
          []
      end

    assign(socket, :volumes, volumes)
  end

  # Returns a map of %{volume_name => [service_name, ...]} for all named volumes
  # referenced in service volume mappings (left side without a leading /).
  defp build_service_bindings do
    Services.list_services()
    |> Enum.flat_map(fn svc ->
      svc.volumes
      |> Enum.map(&(String.split(&1, ":") |> List.first()))
      |> Enum.reject(&(is_nil(&1) or String.starts_with?(&1, "/")))
      |> Enum.map(&{&1, svc})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-5xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-white">Volumes</h1>
        <button
          phx-click="delete_unbound"
          data-confirm="Delete all unbound volumes? This cannot be undone."
          class="text-sm border border-red-900 text-red-500 hover:border-red-700 hover:text-red-400 rounded-lg px-4 py-2 transition-colors"
        >
          Delete all unbound
        </button>
      </div>

      <div class="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-gray-500 border-b border-gray-800">
              <th class="px-5 py-3 font-medium">Name</th>
              <th class="px-5 py-3 font-medium">Driver</th>
              <th class="px-5 py-3 font-medium">Bound to</th>
              <th class="px-5 py-3 font-medium">Created</th>
              <th class="px-5 py-3 font-medium"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800">
            <%= for vol <- @volumes do %>
              <tr class="hover:bg-gray-800/50 transition-colors">
                <td class="px-5 py-3 font-mono text-white text-xs"><%= vol.name %></td>
                <td class="px-5 py-3 text-gray-500 text-xs"><%= vol.driver || "local" %></td>
                <td class="px-5 py-3">
                  <%= if vol.bound_to do %>
                    <div class="flex flex-wrap gap-1">
                      <%= for svc <- vol.bound_to do %>
                        <.link
                          href={~p"/services/#{svc.id}"}
                          class="text-xs text-indigo-400 hover:text-indigo-300 font-medium"
                        >
                          <%= svc.name %>
                        </.link>
                      <% end %>
                    </div>
                  <% else %>
                    <span class="text-xs px-2 py-0.5 rounded-full bg-gray-800 text-gray-500">
                      unbound
                    </span>
                  <% end %>
                </td>
                <td class="px-5 py-3 text-gray-500 text-xs">
                  <%= format_date(vol.created_at) %>
                </td>
                <td class="px-5 py-3 text-right">
                  <%= if is_nil(vol.bound_to) do %>
                    <button
                      phx-click="delete_volume"
                      phx-value-name={vol.name}
                      data-confirm={"Delete volume \"#{vol.name}\"? This cannot be undone."}
                      class="text-xs text-red-500 hover:text-red-400 transition-colors"
                    >
                      Delete
                    </button>
                  <% else %>
                    <span class="text-xs text-gray-700">in use</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
            <%= if @volumes == [] do %>
              <tr>
                <td colspan="5" class="px-5 py-12 text-center text-gray-500">
                  No Podman volumes found.
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <p class="mt-3 text-xs text-gray-600">
        Only named volumes are shown. Bind mounts (host paths starting with <span class="font-mono">/</span>) are not managed here.
      </p>
    </div>
    """
  end

  defp format_date(nil), do: "—"

  defp format_date(dt_string) do
    case DateTime.from_iso8601(dt_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> dt_string
    end
  end
end
