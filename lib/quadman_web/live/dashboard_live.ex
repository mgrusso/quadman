defmodule QuadmanWeb.DashboardLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Services, Deployments, PodmanStatsPoller}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Quadman.PubSub, "services:status")

    {:ok, load_assigns(socket)}
  end

  @impl true
  def handle_info({:status_update, _}, socket) do
    {:noreply, load_assigns(socket)}
  end

  defp load_assigns(socket) do
    services = Services.list_services_with_stack()
    deployments = Deployments.list_deployments(10)
    container_stats = PodmanStatsPoller.all()

    counts = %{
      total: length(services),
      running: Enum.count(services, &(&1.status == "running")),
      stopped: Enum.count(services, &(&1.status == "stopped")),
      failed: Enum.count(services, &(&1.status == "failed"))
    }

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:services, services)
    |> assign(:deployments, deployments)
    |> assign(:counts, counts)
    |> assign(:container_stats, container_stats)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-7xl mx-auto">
      <h1 class="text-2xl font-bold text-white mb-6">Dashboard</h1>

      <%!-- Stat cards --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-8">
        <.stat_card label="Total services" value={@counts.total} color="text-white" />
        <.stat_card label="Running" value={@counts.running} color="text-emerald-400" />
        <.stat_card label="Stopped" value={@counts.stopped} color="text-gray-400" />
        <.stat_card label="Failed" value={@counts.failed} color="text-red-400" />
      </div>

      <%!-- Services table --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl mb-8">
        <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">Services</h2>
          <.link href={~p"/services"} class="text-sm text-indigo-400 hover:text-indigo-300">
            View all &rarr;
          </.link>
        </div>

        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="text-left text-gray-500 border-b border-gray-800">
                <th class="px-5 py-3 font-medium">Name</th>
                <th class="px-5 py-3 font-medium">Image</th>
                <th class="px-5 py-3 font-medium">Stack</th>
                <th class="px-5 py-3 font-medium">CPU</th>
                <th class="px-5 py-3 font-medium">Memory</th>
                <th class="px-5 py-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-800">
              <%= for service <- @services do %>
                <% stats = Map.get(@container_stats, service.name) %>
                <tr class="hover:bg-gray-800/50 transition-colors">
                  <td class="px-5 py-3">
                    <.link href={~p"/services/#{service.id}"} class="text-indigo-400 hover:text-indigo-300 font-medium">
                      <%= service.name %>
                    </.link>
                  </td>
                  <td class="px-5 py-3 text-gray-400 font-mono text-xs truncate max-w-xs">
                    <%= service.image %>
                  </td>
                  <td class="px-5 py-3 text-gray-400">
                    <%= if service.stack, do: service.stack.name, else: "—" %>
                  </td>
                  <td class="px-5 py-3 text-gray-400 text-xs">
                    <%= format_cpu(stats) %>
                  </td>
                  <td class="px-5 py-3 text-gray-400 text-xs">
                    <%= format_mem(stats) %>
                  </td>
                  <td class="px-5 py-3">
                    <.status_badge status={service.status} />
                  </td>
                </tr>
              <% end %>
              <%= if @services == [] do %>
                <tr>
                  <td colspan="4" class="px-5 py-8 text-center text-gray-500">
                    No services yet. <.link href={~p"/services"} class="text-indigo-400 hover:text-indigo-300">Create one &rarr;</.link>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Recent deployments --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl">
        <div class="px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">Recent Deployments</h2>
        </div>
        <div class="divide-y divide-gray-800">
          <%= for d <- @deployments do %>
            <div class="flex items-center justify-between px-5 py-3 hover:bg-gray-800/50 transition-colors">
              <div class="flex items-center gap-3">
                <.status_badge status={d.status} />
                <span class="text-sm text-white"><%= d.service.name %></span>
              </div>
              <div class="flex items-center gap-4 text-xs text-gray-500">
                <span><%= d.triggered_by && d.triggered_by.email || "system" %></span>
                <.link href={~p"/deployments/#{d.id}"} class="text-indigo-400 hover:text-indigo-300">
                  View &rarr;
                </.link>
              </div>
            </div>
          <% end %>
          <%= if @deployments == [] do %>
            <div class="px-5 py-8 text-center text-gray-500 text-sm">No deployments yet.</div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-xl px-5 py-4">
      <div class={["text-3xl font-bold mb-1", @color]}><%= @value %></div>
      <div class="text-sm text-gray-400"><%= @label %></div>
    </div>
    """
  end

  defp format_cpu(nil), do: "—"
  defp format_cpu(stats) do
    case Map.get(stats, "CPU") || Map.get(stats, "cpu_percent") do
      nil -> "—"
      val when is_float(val) -> "#{Float.round(val, 1)}%"
      val when is_binary(val) -> val
      _ -> "—"
    end
  end

  defp format_mem(nil), do: "—"
  defp format_mem(stats) do
    usage = Map.get(stats, "MemUsage") || Map.get(stats, "mem_usage")
    case usage do
      nil -> "—"
      val when is_binary(val) -> val
      val when is_integer(val) -> format_bytes(val)
      _ -> "—"
    end
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
  defp format_bytes(bytes) when bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp format_bytes(bytes),
    do: "#{Float.round(bytes / 1024, 1)} KiB"
end
