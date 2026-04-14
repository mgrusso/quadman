defmodule QuadmanWeb.ServiceLogsLive do
  use QuadmanWeb, :live_view

  alias Quadman.Services

  @max_lines 500

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    service = Services.get_service!(id)

    socket =
      socket
      |> assign(:page_title, "#{service.name} — Logs")
      |> assign(:service, service)
      |> assign(:lines, [])
      |> assign(:port, nil)
      |> assign(:streaming, false)
      |> assign(:tail, "100")

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket) do
      {:noreply, start_stream(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("stop_stream", _params, socket) do
    {:noreply, stop_stream(socket)}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, :lines, [])}
  end

  def handle_event("set_tail", %{"tail" => tail}, socket) do
    socket = stop_stream(socket)
    {:noreply, socket |> assign(:tail, tail) |> start_stream()}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{assigns: %{port: port}} = socket) do
    new_lines =
      data
      |> String.split("\n", trim: true)

    lines =
      (socket.assigns.lines ++ new_lines)
      |> Enum.take(-@max_lines)

    {:noreply, assign(socket, :lines, lines)}
  end

  def handle_info({port, {:exit_status, _}}, %{assigns: %{port: port}} = socket) do
    {:noreply, socket |> assign(:port, nil) |> assign(:streaming, false)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    stop_stream(socket)
    :ok
  end

  defp start_stream(socket) do
    socket = stop_stream(socket)
    service = socket.assigns.service
    tail = socket.assigns.tail

    unit_name = service.unit_name || "#{service.name}.service"

    # Use journalctl for Quadlet/systemd units; fall back is podman logs
    {cmd, args} =
      if service.unit_name do
        {"journalctl", ["--user", "--unit", unit_name, "--no-pager", "--follow", "--lines", tail, "--output", "short-iso"]}
      else
        {"podman", ["logs", "--follow", "--tail", tail, service.name]}
      end

    port =
      try do
        Port.open({:spawn_executable, System.find_executable(cmd)},
          args: args,
          line: 4096,
          stderr_to_stdout: true,
          exit_status: true
        )
      rescue
        _ -> nil
      end

    if port do
      socket |> assign(:port, port) |> assign(:streaming, true)
    else
      socket
      |> assign(:streaming, false)
      |> put_flash(:error, "Could not open log stream (is #{cmd} available?)")
    end
  end

  defp stop_stream(%{assigns: %{port: nil}} = socket), do: socket

  defp stop_stream(%{assigns: %{port: port}} = socket) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    socket |> assign(:port, nil) |> assign(:streaming, false)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-6xl mx-auto flex flex-col" style="height: calc(100vh - 2rem)">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-3">
          <.link href={~p"/services/#{@service.id}"} class="text-gray-500 hover:text-white text-sm">
            <%= @service.name %>
          </.link>
          <span class="text-gray-700">/</span>
          <span class="text-white text-sm font-medium">Logs</span>
        </div>

        <div class="flex items-center gap-3">
          <select phx-change="set_tail" name="tail" class="bg-gray-800 border border-gray-700 text-gray-200 text-sm rounded-lg px-3 py-1.5">
            <option value="50" selected={@tail == "50"}>Last 50 lines</option>
            <option value="100" selected={@tail == "100"}>Last 100 lines</option>
            <option value="500" selected={@tail == "500"}>Last 500 lines</option>
          </select>

          <button phx-click="clear" class="text-sm text-gray-400 hover:text-white border border-gray-700 px-3 py-1.5 rounded-lg">
            Clear
          </button>

          <%= if @streaming do %>
            <button phx-click="stop_stream" class="text-sm text-red-400 hover:text-red-300 border border-red-800 px-3 py-1.5 rounded-lg">
              Stop
            </button>
            <span class="flex items-center gap-1.5 text-xs text-emerald-400">
              <span class="w-2 h-2 bg-emerald-400 rounded-full animate-pulse"></span>
              Live
            </span>
          <% else %>
            <span class="text-xs text-gray-500">Stopped</span>
          <% end %>
        </div>
      </div>

      <div
        id="log-container"
        class="flex-1 bg-gray-950 border border-gray-800 rounded-xl overflow-y-auto p-4 font-mono text-xs text-gray-300 leading-5"
        phx-hook="ScrollBottom"
      >
        <%= for {line, idx} <- Enum.with_index(@lines) do %>
          <div id={"log-#{idx}"} class="whitespace-pre-wrap break-all"><%= line %></div>
        <% end %>
        <%= if @lines == [] do %>
          <div class="text-gray-600">Waiting for log output…</div>
        <% end %>
      </div>
    </div>
    """
  end
end
