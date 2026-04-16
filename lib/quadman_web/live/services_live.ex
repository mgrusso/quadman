defmodule QuadmanWeb.ServicesLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Services, Stacks}
  alias Quadman.Services.Service

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Quadman.PubSub, "services:status")

    {:ok,
     socket
     |> assign(:page_title, "Services")
     |> assign(:services, Services.list_services_with_stack())
     |> assign(:stacks, Stacks.list_stacks())
     |> assign(:show_modal, false)
     |> assign(:form, to_form(Services.change_service(%Service{})))}
  end

  @impl true
  def handle_params(%{"action" => "new"}, _uri, socket) do
    {:noreply, assign(socket, :show_modal, true)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  @impl true
  def handle_event("validate", %{"service" => params}, socket) do
    changeset = Services.change_service(%Service{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"service" => params} = all_params, socket) do
    port_mappings = parse_lines(Map.get(all_params, "port_mappings_text", ""))
    volumes = parse_lines(Map.get(all_params, "volumes_text", ""))

    params =
      params
      |> Map.put("port_mappings", port_mappings)
      |> Map.put("volumes", volumes)

    case Services.create_service(params) do
      {:ok, service} ->
        {:noreply,
         socket
         |> put_flash(:info, "Service \"#{service.name}\" created.")
         |> assign(:services, Services.list_services_with_stack())
         |> push_patch(to: ~p"/services")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/services")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    service = Services.get_service!(id)
    {:ok, _} = Services.delete_service(service)

    {:noreply,
     socket
     |> put_flash(:info, "Service deleted.")
     |> assign(:services, Services.list_services_with_stack())}
  end

  @impl true
  def handle_info({:status_update, _}, socket) do
    {:noreply, assign(socket, :services, Services.list_services_with_stack())}
  end

  defp parse_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-7xl mx-auto">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-white">Services</h1>
        <.link patch={~p"/services?action=new"} class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium px-4 py-2 rounded-lg transition-colors">
          + New service
        </.link>
      </div>

      <div class="bg-gray-900 border border-gray-800 rounded-xl overflow-hidden">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-gray-500 border-b border-gray-800">
              <th class="px-5 py-3 font-medium">Name</th>
              <th class="px-5 py-3 font-medium">Image</th>
              <th class="px-5 py-3 font-medium">Stack</th>
              <th class="px-5 py-3 font-medium">Ports</th>
              <th class="px-5 py-3 font-medium">Domain</th>
              <th class="px-5 py-3 font-medium">Status</th>
              <th class="px-5 py-3 font-medium"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-800">
            <%= for service <- @services do %>
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
                  <%= Enum.join(service.port_mappings, ", ") %>
                </td>
                <td class="px-5 py-3 text-xs">
                  <%= if service.domain do %>
                    <span class="text-indigo-400 font-mono"><%= service.domain %></span>
                  <% else %>
                    <span class="text-gray-600">—</span>
                  <% end %>
                </td>
                <td class="px-5 py-3">
                  <.status_badge status={service.status} />
                </td>
                <td class="px-5 py-3 text-right">
                  <.link
                    href={~p"/services/#{service.id}"}
                    class="text-xs text-gray-400 hover:text-white mr-3"
                  >
                    Manage
                  </.link>
                  <button
                    phx-click="delete"
                    phx-value-id={service.id}
                    data-confirm={"Delete service \"#{service.name}\"?"}
                    class="text-xs text-red-500 hover:text-red-400"
                  >
                    Delete
                  </button>
                </td>
              </tr>
            <% end %>
            <%= if @services == [] do %>
              <tr>
                <td colspan="6" class="px-5 py-12 text-center text-gray-500">
                  No services yet. Create your first one above.
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>

    <%!-- Create modal --%>
    <.modal :if={@show_modal} id="new-service-modal" show on_cancel={JS.push("close_modal")}>
      <div class="text-white">
        <h2 class="text-lg font-semibold mb-5">New Service</h2>

        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
          <.input field={@form[:name]} label="Name" placeholder="my-app" class="bg-gray-800 border-gray-700 text-white" />
          <.input field={@form[:image]} label="Image" placeholder="docker.io/nginx:latest" class="bg-gray-800 border-gray-700 text-white" />

          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:restart_policy]}
              type="select"
              label="Restart policy"
              options={["on-failure", "always", "no", "on-success", "on-abnormal", "on-abort"]}
              class="bg-gray-800 border-gray-700 text-white"
            />
            <.input
              field={@form[:stack_id]}
              type="select"
              label="Stack (optional)"
              options={[{"None", ""}] ++ Enum.map(@stacks, &{&1.name, &1.id})}
              class="bg-gray-800 border-gray-700 text-white"
            />
          </div>

          <.input field={@form[:resource_cpu]} label="CPU limit (e.g. 50%)" placeholder="optional" class="bg-gray-800 border-gray-700 text-white" />
          <.input field={@form[:resource_mem]} label="Memory limit (e.g. 512M)" placeholder="optional" class="bg-gray-800 border-gray-700 text-white" />
          <.input field={@form[:domain]} label="Domain (optional)" placeholder="app.example.com — enables Caddy reverse proxy" class="bg-gray-800 border-gray-700 text-white" />

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">Port mappings (optional)</label>
              <textarea
                name="port_mappings_text"
                rows="3"
                placeholder={"8080:80\n443:443"}
                class="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white font-mono placeholder-gray-500 focus:outline-none focus:border-indigo-500 resize-none"
              ></textarea>
              <p class="text-xs text-gray-600 mt-1">One per line, e.g. <span class="font-mono">8080:80</span></p>
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">Volumes (optional)</label>
              <textarea
                name="volumes_text"
                rows="3"
                placeholder={"/data/app:/app/data"}
                class="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white font-mono placeholder-gray-500 focus:outline-none focus:border-indigo-500 resize-none"
              ></textarea>
              <p class="text-xs text-gray-600 mt-1">One per line, e.g. <span class="font-mono">/host:/container</span></p>
            </div>
          </div>

          <div class="flex justify-end gap-3 pt-2">
            <button type="button" phx-click="close_modal" class="text-sm text-gray-400 hover:text-white px-4 py-2">
              Cancel
            </button>
            <button type="submit" class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium px-5 py-2 rounded-lg transition-colors">
              Create service
            </button>
          </div>
        </.form>
      </div>
    </.modal>
    """
  end
end
