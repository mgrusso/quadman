defmodule QuadmanWeb.StackDetailLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Stacks, Services, Deployments}

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
     |> assign(:confirm_delete_stack, false)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("deploy_all", _params, socket) do
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
  end

  def handle_event("assign_service", %{"service_id" => svc_id}, socket) do
    service = Services.get_service!(svc_id)
    Services.update_service(service, %{stack_id: socket.assigns.stack.id})

    stack = Stacks.get_stack_with_services!(socket.assigns.stack.id)
    all_services = Services.list_services()

    {:noreply,
     socket
     |> assign(:stack, stack)
     |> assign(:unassigned_services, unassigned(all_services, stack))}
  end

  def handle_event("confirm_delete_stack", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_stack, true)}
  end

  def handle_event("cancel_delete_stack", _params, socket) do
    {:noreply, assign(socket, :confirm_delete_stack, false)}
  end

  def handle_event("delete_stack", _params, socket) do
    stack = socket.assigns.stack
    {:ok, _} = Stacks.delete_stack(stack)

    {:noreply,
     socket
     |> put_flash(:info, "Stack \"#{stack.name}\" deleted.")
     |> push_navigate(to: ~p"/stacks")}
  end

  def handle_event("remove_service", %{"service_id" => svc_id}, socket) do
    service = Services.get_service!(svc_id)
    Services.update_service(service, %{stack_id: nil})

    stack = Stacks.get_stack_with_services!(socket.assigns.stack.id)
    all_services = Services.list_services()

    {:noreply,
     socket
     |> assign(:stack, stack)
     |> assign(:unassigned_services, unassigned(all_services, stack))}
  end

  @impl true
  def handle_info({:status_update, _}, socket) do
    stack = Stacks.get_stack_with_services!(socket.assigns.stack.id)
    {:noreply, assign(socket, :stack, stack)}
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
