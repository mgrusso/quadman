defmodule QuadmanWeb.StackDetailLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Stacks, Services, Deployments, Compose}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Quadman.PubSub, "services:status")

    stack = Stacks.get_stack_with_services!(id)
    all_services = Services.list_services()

    {:ok,
     socket
     |> assign(:page_title, stack.name)
     |> assign(:stack, stack)
     |> assign(:all_services, all_services)
     |> assign(:unassigned_services, unassigned(all_services, stack))
     |> assign(:confirm_delete_stack, false)
     |> assign(:compose_yaml_input, stack.compose_yaml || "")
     |> assign(:compose_error, nil)
     |> assign(:compose_warnings, [])
     |> assign(:compose_saving, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("deploy_all", _params, socket) do
    with_admin(socket, fn ->
      stack = socket.assigns.stack
      user = socket.assigns.current_user

      results =
        Enum.map(stack.services, fn svc ->
          Deployments.deploy_service(svc.id, user.id)
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors == [] do
        {:noreply, put_flash(socket, :info, "Deployments queued for all #{length(stack.services)} services.")}
      else
        {:noreply, put_flash(socket, :error, "#{length(errors)} deployment(s) failed to queue.")}
      end
    end)
  end

  def handle_event("assign_service", %{"service_id" => svc_id}, socket) do
    with_admin(socket, fn ->
      service = Services.get_service!(svc_id)
      Services.update_service(service, %{stack_id: socket.assigns.stack.id})

      stack = Stacks.get_stack_with_services!(socket.assigns.stack.id)
      all_services = Services.list_services()

      {:noreply,
       socket
       |> assign(:stack, stack)
       |> assign(:unassigned_services, unassigned(all_services, stack))}
    end)
  end

  def handle_event("confirm_delete_stack", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_stack, true)}
  end

  def handle_event("cancel_delete_stack", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_stack, false)}
  end

  def handle_event("delete_stack", _params, socket) do
    with_admin(socket, fn ->
      stack = socket.assigns.stack
      {:ok, _} = Stacks.delete_stack_with_services(stack)

      {:noreply,
       socket
       |> put_flash(:info, "Stack \"#{stack.name}\" deleted.")
       |> push_navigate(to: ~p"/stacks")}
    end)
  end

  def handle_event("remove_service", %{"service_id" => svc_id}, socket) do
    with_admin(socket, fn ->
      service = Services.get_service!(svc_id)
      Services.update_service(service, %{stack_id: nil})

      stack = Stacks.get_stack_with_services!(socket.assigns.stack.id)
      all_services = Services.list_services()

      {:noreply,
       socket
       |> assign(:stack, stack)
       |> assign(:unassigned_services, unassigned(all_services, stack))}
    end)
  end

  def handle_event("compose_yaml_input", %{"yaml" => yaml}, socket) do
    {error, warnings} =
      case Compose.parse(yaml) do
        {:ok, _, warns} -> {nil, warns}
        {:error, reason} when yaml != "" -> {reason, []}
        _ -> {nil, []}
      end

    {:noreply,
     socket
     |> assign(:compose_yaml_input, yaml)
     |> assign(:compose_error, error)
     |> assign(:compose_warnings, warnings)}
  end

  def handle_event("save_compose", %{"yaml" => yaml}, socket) do
    with_admin(socket, fn ->
      socket = assign(socket, :compose_saving, true)

      case Stacks.update_compose_yaml(socket.assigns.stack, yaml, socket.assigns.current_user.id) do
        {:ok, %{created: c, updated: u, removed: r}, warnings} ->
          stack = Stacks.get_stack_with_services!(socket.assigns.stack.id)
          msg = "Saved & redeployed — #{c} created, #{u} updated, #{r} removed."

          socket =
            socket
            |> assign(:stack, stack)
            |> assign(:compose_yaml_input, yaml)
            |> assign(:compose_saving, false)
            |> assign(:compose_warnings, warnings)
            |> assign(:compose_error, nil)
            |> put_flash(:info, msg)

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:compose_saving, false)
           |> assign(:compose_error, reason)}
      end
    end)
  end

  @impl true
  def handle_info({:status_update, _}, socket) do
    stack = Stacks.get_stack_with_services!(socket.assigns.stack.id)
    {:noreply, assign(socket, :stack, stack)}
  end

  defp with_admin(socket, fun) do
    if socket.assigns.current_user.role == "admin" do
      fun.()
    else
      {:noreply, put_flash(socket, :error, "Admin access required.")}
    end
  end

  defp unassigned(all_services, stack) do
    stack_ids = MapSet.new(stack.services, & &1.id)
    Enum.reject(all_services, &MapSet.member?(stack_ids, &1.id))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-4xl mx-auto">
      <div class="flex items-center gap-3 mb-1 text-sm">
        <.link href={~p"/stacks"} class="text-gray-500 hover:text-white">Stacks</.link>
        <span class="text-gray-700">/</span>
        <span class="text-white font-medium"><%= @stack.name %></span>
      </div>

      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center gap-3">
          <h1 class="text-2xl font-bold text-white"><%= @stack.name %></h1>
          <span class="text-xs text-gray-500 bg-gray-800 px-2 py-0.5 rounded"><%= @stack.quadlet_type %></span>
          <.status_badge status={Stacks.compute_stack_status(@stack)} />
        </div>

        <div class="flex items-center gap-2">
          <%= if @confirm_delete_stack do %>
            <span class="text-sm text-gray-400">Delete stack?</span>
            <button phx-click="delete_stack" class="text-sm text-red-400 border border-red-700 hover:border-red-500 px-3 py-1.5 rounded-lg transition-colors">
              Yes, delete
            </button>
            <button phx-click="cancel_delete_stack" class="text-sm text-gray-400 hover:text-white px-2 py-1.5">
              Cancel
            </button>
          <% else %>
            <button
              phx-click="confirm_delete_stack"
              class="text-sm text-red-500 hover:text-red-400 border border-red-900 hover:border-red-700 px-3 py-1.5 rounded-lg transition-colors"
            >
              Delete stack
            </button>
          <% end %>

          <button
            phx-click="deploy_all"
            disabled={@stack.services == []}
            class="bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white text-sm font-medium px-4 py-2 rounded-lg transition-colors"
          >
            Deploy all
          </button>
        </div>
      </div>

      <%!-- Services in stack --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden mb-6">
        <div class="px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">Services (<%= length(@stack.services) %>)</h2>
        </div>
        <div class="divide-y divide-gray-800">
          <%= for svc <- @stack.services do %>
            <div class="flex items-center justify-between px-5 py-3">
              <div class="flex items-center gap-3">
                <.link href={~p"/services/#{svc.id}"} class="text-indigo-400 hover:text-indigo-300 text-sm font-medium">
                  <%= svc.name %>
                </.link>
                <.status_badge status={svc.status} />
              </div>
              <div class="flex items-center gap-3">
                <.link href={~p"/services/#{svc.id}"} class="text-xs text-gray-400 hover:text-white">
                  Manage
                </.link>
                <button
                  phx-click="remove_service"
                  phx-value-service_id={svc.id}
                  class="text-xs text-gray-500 hover:text-red-400"
                >
                  Remove
                </button>
              </div>
            </div>
          <% end %>
          <%= if @stack.services == [] do %>
            <div class="px-5 py-8 text-center text-gray-500 text-sm">No services assigned yet.</div>
          <% end %>
        </div>
      </div>

      <%!-- Compose YAML editor (only for compose-backed stacks) --%>
      <%= if @stack.compose_yaml do %>
        <div class="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden mb-6">
          <div class="px-5 py-4 border-b border-gray-800 flex items-center justify-between">
            <div class="flex items-center gap-2">
              <h2 class="font-semibold text-white">Compose YAML</h2>
              <span class="text-xs text-emerald-700 bg-emerald-950 border border-emerald-900 px-2 py-0.5 rounded">compose</span>
            </div>
            <p class="text-xs text-gray-500">Edit and save to reconcile services and redeploy changed ones.</p>
          </div>
          <div class="p-5">
            <form phx-submit="save_compose">
              <textarea
                name="yaml"
                rows="20"
                phx-change="compose_yaml_input"
                phx-debounce="400"
                class="w-full bg-gray-950 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white font-mono focus:outline-none focus:border-indigo-500 resize-y mb-3"
              ><%= @compose_yaml_input %></textarea>

              <%= if @compose_error do %>
                <div class="bg-red-950 border border-red-800 rounded-lg px-4 py-3 text-sm text-red-300 mb-3">
                  <span class="font-medium">Error:</span> <%= @compose_error %>
                </div>
              <% end %>

              <%= if @compose_warnings != [] do %>
                <div class="bg-yellow-950 border border-yellow-800 rounded-lg px-4 py-3 text-sm text-yellow-300 mb-3 space-y-1">
                  <p class="font-medium">Warnings:</p>
                  <%= for w <- @compose_warnings do %>
                    <p class="text-xs">• <%= w %></p>
                  <% end %>
                </div>
              <% end %>

              <div class="flex justify-end">
                <button
                  type="submit"
                  disabled={@compose_saving or @compose_error != nil}
                  class="bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white text-sm font-medium px-5 py-2 rounded-lg transition-colors"
                >
                  <%= if @compose_saving, do: "Saving…", else: "Save & Redeploy" %>
                </button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <%!-- Add existing services --%>
      <%= if @unassigned_services != [] do %>
        <div class="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
          <div class="px-5 py-4 border-b border-gray-800">
            <h2 class="font-semibold text-white">Add existing services</h2>
          </div>
          <div class="divide-y divide-gray-800">
            <%= for svc <- @unassigned_services do %>
              <div class="flex items-center justify-between px-5 py-3">
                <div class="flex items-center gap-3">
                  <span class="text-sm text-gray-200"><%= svc.name %></span>
                  <span class="text-xs font-mono text-gray-500"><%= svc.image %></span>
                </div>
                <button
                  phx-click="assign_service"
                  phx-value-service_id={svc.id}
                  class="text-xs text-indigo-400 hover:text-indigo-300"
                >
                  + Add to stack
                </button>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
