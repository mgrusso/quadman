defmodule QuadmanWeb.StacksLive do
  use QuadmanWeb, :live_view

  alias Quadman.Stacks
  alias Quadman.Stacks.Stack

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Stacks")
     |> assign(:stacks, Stacks.list_stacks_with_services())
     |> assign(:show_modal, false)
     |> assign(:form, to_form(Stacks.change_stack(%Stack{})))}
  end

  @impl true
  def handle_params(%{"action" => "new"}, _uri, socket) do
    {:noreply, assign(socket, :show_modal, true)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  @impl true
  def handle_event("validate", %{"stack" => params}, socket) do
    changeset = Stacks.change_stack(%Stack{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"stack" => params}, socket) do
    case Stacks.create_stack(params) do
      {:ok, stack} ->
        {:noreply,
         socket
         |> put_flash(:info, "Stack \"#{stack.name}\" created.")
         |> assign(:stacks, Stacks.list_stacks_with_services())
         |> push_patch(to: ~p"/stacks")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/stacks")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    stack = Stacks.get_stack!(id)
    {:ok, _} = Stacks.delete_stack(stack)

    {:noreply,
     socket
     |> put_flash(:info, "Stack deleted.")
     |> assign(:stacks, Stacks.list_stacks_with_services())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-5xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-white">Stacks</h1>
        <.link patch={~p"/stacks?action=new"} class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium px-4 py-2 rounded-lg transition-colors">
          + New stack
        </.link>
      </div>

      <div class="space-y-4">
        <%= for stack <- @stacks do %>
          <div class="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
            <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
              <div class="flex items-center gap-3">
                <.link href={~p"/stacks/#{stack.id}"} class="text-white font-medium hover:text-indigo-400">
                  <%= stack.name %>
                </.link>
                <span class="text-xs text-gray-500 bg-gray-800 px-2 py-0.5 rounded"><%= stack.quadlet_type %></span>
                <.status_badge status={Stacks.compute_stack_status(stack)} />
              </div>
              <div class="flex items-center gap-3">
                <.link href={~p"/stacks/#{stack.id}"} class="text-xs text-gray-400 hover:text-white">
                  Manage
                </.link>
                <button
                  phx-click="delete"
                  phx-value-id={stack.id}
                  data-confirm={"Delete stack \"#{stack.name}\" and detach its services?"}
                  class="text-xs text-red-500 hover:text-red-400"
                >
                  Delete
                </button>
              </div>
            </div>

            <div class="px-5 py-3">
              <%= if stack.services == [] do %>
                <p class="text-sm text-gray-500">No services in this stack.</p>
              <% else %>
                <div class="flex flex-wrap gap-2">
                  <%= for svc <- stack.services do %>
                    <.link
                      href={~p"/services/#{svc.id}"}
                      class="flex items-center gap-1.5 bg-gray-800 hover:bg-gray-700 rounded-lg px-3 py-1.5 text-xs transition-colors"
                    >
                      <span class="text-gray-200"><%= svc.name %></span>
                      <.status_badge status={svc.status} />
                    </.link>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @stacks == [] do %>
          <div class="bg-gray-900 border border-gray-800 rounded-xl px-5 py-12 text-center text-gray-500">
            No stacks yet. Create one to group related services.
          </div>
        <% end %>
      </div>
    </div>

    <.modal :if={@show_modal} id="new-stack-modal" show on_cancel={JS.push("close_modal")}>
      <div class="text-white">
        <h2 class="text-lg font-semibold mb-5">New Stack</h2>

        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name" placeholder="my-stack" />
          <.input
            field={@form[:quadlet_type]}
            type="select"
            label="Type"
            options={[{"Multi-container", "multi_container"}, {"Pod", "pod"}]}
          />

          <div class="flex justify-end gap-3 pt-2">
            <button type="button" phx-click="close_modal" class="text-sm text-gray-400 hover:text-white px-4 py-2">
              Cancel
            </button>
            <button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium px-5 py-2 rounded-lg transition-colors">
              Create stack
            </button>
          </div>
        </.form>
      </div>
    </.modal>
    """
  end
end
