defmodule QuadmanWeb.DeploymentDetailLive do
  use QuadmanWeb, :live_view

  alias Quadman.Deployments

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    deployment = Deployments.get_deployment_with_logs!(id)

    if connected?(socket) and deployment.status in ["pending", "running"] do
      Phoenix.PubSub.subscribe(Quadman.PubSub, "deployment:#{id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Deployment — #{deployment.service.name}")
     |> assign(:deployment, deployment)
     |> assign(:logs, deployment.logs)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:log, entry}, socket) do
    {:noreply, assign(socket, :logs, socket.assigns.logs ++ [entry])}
  end

  def handle_info({:status, status}, socket) do
    deployment = Map.put(socket.assigns.deployment, :status, status)
    {:noreply, assign(socket, :deployment, deployment)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-4xl mx-auto">
      <div class="flex items-center gap-3 mb-1 text-sm">
        <.link href={~p"/services/#{@deployment.service_id}"} class="text-gray-500 hover:text-white">
          <%= @deployment.service.name %>
        </.link>
        <span class="text-gray-700">/</span>
        <span class="text-gray-400">Deployment</span>
      </div>

      <div class="flex items-center gap-3 mb-6">
        <h1 class="text-2xl font-bold text-white">Deploy</h1>
        <.status_badge status={@deployment.status} />
      </div>

      <%!-- Meta --%>
      <div class="grid grid-cols-3 gap-4 mb-6">
        <div class="bg-gray-900 border border-gray-800 rounded-xl px-4 py-3">
          <div class="text-xs text-gray-500 mb-1">Triggered by</div>
          <div class="text-sm text-white truncate">
            <%= @deployment.triggered_by && @deployment.triggered_by.email || "system" %>
          </div>
        </div>
        <div class="bg-gray-900 border border-gray-800 rounded-xl px-4 py-3">
          <div class="text-xs text-gray-500 mb-1">Image digest</div>
          <div class="text-sm text-white font-mono truncate">
            <%= if @deployment.image_digest, do: String.slice(@deployment.image_digest, 0..23), else: "—" %>
          </div>
        </div>
        <div class="bg-gray-900 border border-gray-800 rounded-xl px-4 py-3">
          <div class="text-xs text-gray-500 mb-1">Started</div>
          <div class="text-sm text-white"><%= Calendar.strftime(@deployment.inserted_at, "%Y-%m-%d %H:%M:%S") %></div>
        </div>
      </div>

      <%!-- Log stream --%>
      <div class="bg-gray-950 border border-gray-800 rounded-xl overflow-hidden">
        <div class="flex items-center justify-between px-4 py-2.5 border-b border-gray-800">
          <span class="text-sm font-medium text-white">Deployment log</span>
          <%= if @deployment.status in ["pending", "running"] do %>
            <span class="flex items-center gap-1.5 text-xs text-emerald-400">
              <span class="w-2 h-2 bg-emerald-400 rounded-full animate-pulse"></span>
              Live
            </span>
          <% end %>
        </div>
        <div
          id="deploy-log"
          class="p-4 font-mono text-xs leading-5 overflow-y-auto max-h-[60vh]"
          phx-hook="ScrollBottom"
        >
          <%= for {entry, idx} <- Enum.with_index(@logs) do %>
            <div id={"log-entry-#{idx}"} class={log_line_class(entry)}>
              <span class="text-gray-600 mr-2 select-none">
                <%= if is_struct(entry, Quadman.Deployments.DeploymentLog),
                      do: Calendar.strftime(entry.inserted_at, "%H:%M:%S"),
                      else: "" %>
              </span>
              <%= if is_struct(entry, Quadman.Deployments.DeploymentLog),
                    do: entry.message,
                    else: entry.message %>
            </div>
          <% end %>
          <%= if @logs == [] do %>
            <div class="text-gray-600">Waiting for log output…</div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp log_line_class(%{level: "error"}), do: "text-red-400 whitespace-pre-wrap"
  defp log_line_class(%{level: "warn"}), do: "text-yellow-400 whitespace-pre-wrap"
  defp log_line_class(_), do: "text-gray-300 whitespace-pre-wrap"
end
