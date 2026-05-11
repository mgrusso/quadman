defmodule QuadmanWeb.StacksLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Stacks, Compose}
  alias Quadman.Stacks.Stack

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Stacks")
     |> assign(:stacks, Stacks.list_stacks_with_services())
     |> assign(:show_modal, false)
     |> assign(:show_compose_modal, false)
     |> assign(:compose_name, "")
     |> assign(:compose_yaml, "")
     |> assign(:compose_error, nil)
     |> assign(:compose_warnings, [])
     |> assign(:compose_preview, [])
     |> assign(:form, to_form(Stacks.change_stack(%Stack{})))}
  end

  @impl true
  def handle_params(%{"action" => "new"}, _uri, socket) do
    {:noreply, assign(socket, :show_modal, true)}
  end

  def handle_params(%{"action" => "import"}, _uri, socket) do
    {:noreply, assign(socket, :show_compose_modal, true)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:show_modal, false) |> assign(:show_compose_modal, false)}
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

  def handle_event("close_compose_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_compose_modal, false)
     |> assign(:compose_yaml, "")
     |> assign(:compose_name, "")
     |> assign(:compose_error, nil)
     |> assign(:compose_warnings, [])
     |> assign(:compose_preview, [])
     |> push_patch(to: ~p"/stacks")}
  end

  def handle_event("compose_yaml_change", %{"yaml" => yaml} = params, socket) do
    name = Map.get(params, "name", socket.assigns.compose_name)

    name =
      if name == "" do
        case Compose.extract_name(yaml) do
          {:ok, extracted} -> extracted
          :not_found -> ""
        end
      else
        name
      end

    {error, warnings, preview} =
      case Compose.parse(yaml) do
        {:ok, attrs, warns} ->
          {nil, warns, Enum.map(attrs, &Map.take(&1, [:name, :image, :compose_service_key]))}
        {:error, reason} when yaml != "" ->
          {reason, [], []}
        _ ->
          {nil, [], []}
      end

    {:noreply,
     socket
     |> assign(:compose_yaml, yaml)
     |> assign(:compose_name, name)
     |> assign(:compose_error, error)
     |> assign(:compose_warnings, warnings)
     |> assign(:compose_preview, preview)}
  end

  def handle_event("import_compose", %{"name" => name, "yaml" => yaml}, socket) do
    user_id = socket.assigns.current_user.id

    case Stacks.create_from_compose(name, yaml, user_id) do
      {:ok, stack, warnings} ->
        msg =
          if warnings == [],
            do: "Stack \"#{stack.name}\" imported and deployments queued.",
            else: "Stack \"#{stack.name}\" imported with #{length(warnings)} warning(s)."

        {:noreply,
         socket
         |> put_flash(:info, msg)
         |> push_navigate(to: ~p"/stacks/#{stack.id}")}

      {:error, reason} ->
        {:noreply, assign(socket, :compose_error, reason)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    stack = Stacks.get_stack!(id)
    {:ok, _} = Stacks.delete_stack_with_services(stack)

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
        <div class="flex items-center gap-2">
          <.link
            patch={~p"/stacks?action=import"}
            class="border border-indigo-800 hover:border-indigo-600 text-indigo-400 hover:text-indigo-300 text-sm font-medium px-4 py-2 rounded-lg transition-colors"
          >
            Import Compose
          </.link>
          <.link
            patch={~p"/stacks?action=new"}
            class="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-medium px-4 py-2 rounded-lg transition-colors"
          >
            + New stack
          </.link>
        </div>
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
                <%= if stack.compose_yaml do %>
                  <span class="text-xs text-emerald-700 bg-emerald-950 border border-emerald-900 px-2 py-0.5 rounded">compose</span>
                <% end %>
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
            No stacks yet. Create one or import a docker-compose.yaml.
          </div>
        <% end %>
      </div>
    </div>

    <%!-- New stack modal --%>
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

    <%!-- Import Compose modal --%>
    <.modal :if={@show_compose_modal} id="import-compose-modal" show on_cancel={JS.push("close_compose_modal")}>
      <div class="text-white">
        <h2 class="text-lg font-semibold mb-1">Import docker-compose.yaml</h2>
        <p class="text-sm text-gray-400 mb-5">
          Paste your compose file below. Each service becomes a Quadman service in a new stack.
          <br />Unsupported fields (<code class="text-gray-300">build</code>, <code class="text-gray-300">networks</code>, <code class="text-gray-300">depends_on</code>) are ignored.
        </p>

        <form phx-submit="import_compose" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Stack name</label>
            <input
              type="text"
              name="name"
              value={@compose_name}
              placeholder="my-app"
              required
              class="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-indigo-500"
            />
          </div>

          <div>
            <label class="block text-sm font-medium text-gray-300 mb-1">Compose YAML</label>
            <textarea
              name="yaml"
              rows="16"
              placeholder={"services:\n  web:\n    image: nginx:alpine\n    ports:\n      - \"8080:80\""}
              phx-change="compose_yaml_change"
              phx-debounce="300"
              class="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white font-mono placeholder-gray-600 focus:outline-none focus:border-indigo-500 resize-y"
            ><%= @compose_yaml %></textarea>
          </div>

          <%!-- Parse error --%>
          <%= if @compose_error do %>
            <div class="bg-red-950 border border-red-800 rounded-lg px-4 py-3 text-sm text-red-300">
              <span class="font-medium">Error:</span> <%= @compose_error %>
            </div>
          <% end %>

          <%!-- Warnings --%>
          <%= if @compose_warnings != [] do %>
            <div class="bg-yellow-950 border border-yellow-800 rounded-lg px-4 py-3 text-sm text-yellow-300 space-y-1">
              <p class="font-medium mb-1">Warnings:</p>
              <%= for w <- @compose_warnings do %>
                <p class="text-xs">• <%= w %></p>
              <% end %>
            </div>
          <% end %>

          <%!-- Preview --%>
          <%= if @compose_preview != [] do %>
            <div class="bg-gray-800 border border-gray-700 rounded-lg px-4 py-3">
              <p class="text-xs font-medium text-gray-400 mb-2">Services to be created:</p>
              <div class="space-y-1">
                <%= for svc <- @compose_preview do %>
                  <div class="flex items-center gap-2 text-xs">
                    <span class="text-white font-medium"><%= svc.name %></span>
                    <span class="text-gray-500">←</span>
                    <span class="text-gray-400 font-mono"><%= svc.image %></span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <div class="flex justify-end gap-3 pt-2">
            <button
              type="button"
              phx-click="close_compose_modal"
              class="text-sm text-gray-400 hover:text-white px-4 py-2"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={@compose_error != nil or @compose_preview == []}
              class="bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white text-sm font-medium px-5 py-2 rounded-lg transition-colors"
            >
              Import & deploy
            </button>
          </div>
        </form>
      </div>
    </.modal>
    """
  end
end
