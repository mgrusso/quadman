defmodule QuadmanWeb.ServiceLogsLive do
  use QuadmanWeb, :live_view

  alias Quadman.Services

  @max_lines 1000

  # Common install paths tried in order when not found in PATH
  @podman_candidates ~w(/usr/bin/podman /bin/podman /usr/local/bin/podman)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    service = Services.get_service!(id)

    {:ok,
     socket
     |> assign(:page_title, "#{service.name} — Logs")
     |> assign(:service, service)
     |> assign(:lines, [])
     |> assign(:buffer, "")
     |> assign(:port, nil)
     |> assign(:streaming, false)
     |> assign(:tail, "200")
     |> assign(:at_bottom, true)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if connected?(socket), do: {:noreply, start_stream(socket)}, else: {:noreply, socket}
  end

  @impl true
  def handle_event("start_stream", _params, socket), do: {:noreply, start_stream(socket)}
  def handle_event("stop_stream", _params, socket),  do: {:noreply, stop_stream(socket)}

  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, :lines, [])}
  end

  def handle_event("set_tail", %{"tail" => tail}, socket) do
    {:noreply, socket |> stop_stream() |> assign(:tail, tail) |> start_stream()}
  end

  def handle_event("scroll_position", %{"at_bottom" => at_bottom}, socket) do
    {:noreply, assign(socket, :at_bottom, at_bottom)}
  end

  @impl true
  # Raw binary chunk from Port (no :line option) — accumulate and flush complete lines
  def handle_info({port, {:data, data}}, %{assigns: %{port: port}} = socket) do
    buffer = socket.assigns.buffer <> data
    {complete, new_buffer} = split_buffer(buffer)

    new_lines = complete |> Enum.map(&strip_ansi/1) |> Enum.reject(&(&1 == ""))
    lines = (socket.assigns.lines ++ new_lines) |> Enum.take(-@max_lines)

    {:noreply, socket |> assign(:lines, lines) |> assign(:buffer, new_buffer)}
  end

  def handle_info({port, {:exit_status, _}}, %{assigns: %{port: port}} = socket) do
    {:noreply, socket |> assign(:port, nil) |> assign(:streaming, false) |> assign(:buffer, "")}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    stop_stream(socket)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Stream management
  # ---------------------------------------------------------------------------

  defp start_stream(socket) do
    socket = stop_stream(socket)
    service = socket.assigns.service
    tail = socket.assigns.tail
    container_name = "systemd-#{service.name}"

    tail_arg = if tail == "all", do: "all", else: tail

    args = [
      "logs",
      "--follow",
      "--tail", tail_arg,
      "--names",
      container_name
    ]

    case find_executable("podman") do
      nil ->
        put_flash(socket, :error, "podman not found. Check server PATH.")

      exe ->
        port =
          try do
            Port.open(
              {:spawn_executable, exe},
              args: args,
              stderr_to_stdout: true,
              exit_status: true
            )
          rescue
            e -> {:error, e}
          end

        if is_port(port) do
          socket |> assign(:port, port) |> assign(:streaming, true) |> assign(:buffer, "")
        else
          put_flash(socket, :error, "Could not start log stream.")
        end
    end
  end

  defp stop_stream(%{assigns: %{port: nil}} = socket), do: socket

  defp stop_stream(%{assigns: %{port: port}} = socket) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    socket |> assign(:port, nil) |> assign(:streaming, false) |> assign(:buffer, "")
  end

  defp find_executable(name) do
    System.find_executable(name) ||
      Enum.find(@podman_candidates, &File.exists?/1)
  end

  # ---------------------------------------------------------------------------
  # Line helpers
  # ---------------------------------------------------------------------------

  defp split_buffer(buffer) do
    case String.split(buffer, "\n") do
      [single]  -> {[], single}
      parts     -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  # Strip common ANSI escape sequences
  defp strip_ansi(str), do: String.replace(str, ~r/\e\[[0-9;]*[mGKHFABCDJsur]/, "")

  defp line_class(line) do
    cond do
      String.match?(line, ~r/\b(FATAL|CRIT|ERROR|error|fatal|critical)\b/) -> "text-red-400"
      String.match?(line, ~r/\b(WARN|WARNING|warn|warning)\b/)              -> "text-yellow-400"
      String.match?(line, ~r/\b(DEBUG|debug|TRACE|trace)\b/)                -> "text-gray-500"
      true                                                                   -> "text-gray-300"
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col" style="height: 100vh">
      <%!-- Toolbar --%>
      <div class="flex items-center justify-between px-6 py-3 border-b border-gray-800 bg-gray-950 shrink-0">
        <div class="flex items-center gap-3">
          <.link href={~p"/services/#{@service.id}"} class="text-gray-500 hover:text-white text-sm transition-colors">
            <%= @service.name %>
          </.link>
          <span class="text-gray-700">/</span>
          <span class="text-white text-sm font-medium">Logs</span>
          <span class="text-xs text-gray-600 font-mono"><%= length(@lines) %> lines</span>
        </div>

        <div class="flex items-center gap-2">
          <select
            phx-change="set_tail"
            name="tail"
            class="bg-gray-900 border border-gray-700 text-gray-300 text-xs rounded-lg px-2.5 py-1.5 focus:outline-none focus:border-indigo-500"
          >
            <option value="50"  selected={@tail == "50"}>Last 50</option>
            <option value="200" selected={@tail == "200"}>Last 200</option>
            <option value="500" selected={@tail == "500"}>Last 500</option>
            <option value="all" selected={@tail == "all"}>All</option>
          </select>

          <button
            phx-click="clear"
            class="text-xs text-gray-400 hover:text-white border border-gray-700 hover:border-gray-500 px-3 py-1.5 rounded-lg transition-colors"
          >
            Clear
          </button>

          <%= if @streaming do %>
            <button
              phx-click="stop_stream"
              class="text-xs text-red-400 hover:text-red-300 border border-red-900 hover:border-red-700 px-3 py-1.5 rounded-lg transition-colors"
            >
              Stop
            </button>
            <div class="flex items-center gap-1.5">
              <span class="w-2 h-2 bg-emerald-400 rounded-full animate-pulse"></span>
              <span class="text-xs text-emerald-400 font-medium">Live</span>
            </div>
          <% else %>
            <button
              phx-click="start_stream"
              class="text-xs text-indigo-400 hover:text-indigo-300 border border-indigo-800 hover:border-indigo-600 px-3 py-1.5 rounded-lg transition-colors"
            >
              Stream
            </button>
            <span class="text-xs text-gray-600">Stopped</span>
          <% end %>
        </div>
      </div>

      <%!-- Log output area --%>
      <div class="relative flex-1 min-h-0">
        <div
          id="log-container"
          phx-hook="LogStream"
          class="absolute inset-0 overflow-y-auto bg-gray-950 p-4 font-mono text-xs leading-5"
        >
          <%= if @lines == [] do %>
            <p class="text-gray-600 italic">Waiting for log output…</p>
          <% else %>
            <%= for {line, idx} <- Enum.with_index(@lines) do %>
              <div id={"l-#{idx}"} class={["whitespace-pre-wrap break-all", line_class(line)]}><%= line %></div>
            <% end %>
          <% end %>
        </div>

        <%!-- Jump-to-bottom button (visible only when user has scrolled up) --%>
        <%= unless @at_bottom do %>
          <button
            phx-click="scroll_position"
            phx-value-at_bottom="true"
            onclick="(function(){var el=document.getElementById('log-container');el.scrollTop=el.scrollHeight})()"
            class="absolute bottom-4 right-6 flex items-center gap-1.5 bg-gray-800 hover:bg-gray-700 border border-gray-600 text-gray-300 text-xs px-3 py-2 rounded-lg shadow-lg transition-colors"
          >
            ↓ Jump to bottom
          </button>
        <% end %>
      </div>
    </div>
    """
  end
end
