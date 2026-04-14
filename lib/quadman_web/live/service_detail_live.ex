defmodule QuadmanWeb.ServiceDetailLive do
  use QuadmanWeb, :live_view

  alias Quadman.{Services, Deployments, Systemd, Quadlets, Caddy}
  alias Quadman.Services.EnvironmentVariable

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    service = Services.get_service_with_env!(id)
    Phoenix.PubSub.subscribe(Quadman.PubSub, "services:status")

    {:ok,
     socket
     |> assign(:page_title, service.name)
     |> assign(:service, service)
     |> assign(:deployments, Deployments.list_deployments_for_service(id))
     |> assign(:env_vars, service.environment_variables)
     |> assign(:new_env_form, new_env_form())
     |> assign(:domain_form, to_form(%{"domain" => service.domain || ""}))
     |> assign(:action_loading, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # --- Service control actions ---

  @impl true
  def handle_event("start", _params, socket) do
    socket = assign(socket, :action_loading, :start)
    service = socket.assigns.service
    unit = Quadlets.unit_name(service.name)

    case Systemd.start(unit) do
      :ok ->
        Services.update_service_status(service, "running")
        {:noreply,
         socket
         |> assign(:action_loading, nil)
         |> assign(:service, Services.get_service_with_env!(service.id))
         |> put_flash(:info, "Service started.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:action_loading, nil)
         |> put_flash(:error, "Failed to start: #{reason}")}
    end
  end

  def handle_event("stop", _params, socket) do
    socket = assign(socket, :action_loading, :stop)
    service = socket.assigns.service
    unit = Quadlets.unit_name(service.name)

    case Systemd.stop(unit) do
      :ok ->
        Services.update_service_status(service, "stopped")
        {:noreply,
         socket
         |> assign(:action_loading, nil)
         |> assign(:service, Services.get_service_with_env!(service.id))
         |> put_flash(:info, "Service stopped.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:action_loading, nil)
         |> put_flash(:error, "Failed to stop: #{reason}")}
    end
  end

  def handle_event("restart", _params, socket) do
    socket = assign(socket, :action_loading, :restart)
    service = socket.assigns.service
    unit = Quadlets.unit_name(service.name)

    case Systemd.restart(unit) do
      :ok ->
        Services.update_service_status(service, "running")
        {:noreply,
         socket
         |> assign(:action_loading, nil)
         |> assign(:service, Services.get_service_with_env!(service.id))
         |> put_flash(:info, "Service restarted.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:action_loading, nil)
         |> put_flash(:error, "Failed to restart: #{reason}")}
    end
  end

  def handle_event("deploy", _params, socket) do
    socket = assign(socket, :action_loading, :deploy)
    service = socket.assigns.service
    user = socket.assigns.current_user

    case Deployments.deploy_service(service.id, user.id) do
      {:ok, deployment} ->
        {:noreply,
         socket
         |> assign(:action_loading, nil)
         |> assign(:deployments, Deployments.list_deployments_for_service(service.id))
         |> put_flash(:info, "Deployment queued.")
         |> push_navigate(to: ~p"/deployments/#{deployment.id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:action_loading, nil)
         |> put_flash(:error, "Failed to queue deploy: #{inspect(reason)}")}
    end
  end

  # --- Env var management ---

  def handle_event("validate_env", %{"environment_variable" => params}, socket) do
    changeset =
      %EnvironmentVariable{}
      |> EnvironmentVariable.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_env_form, to_form(changeset, as: :environment_variable))}
  end

  def handle_event("add_env", %{"environment_variable" => params}, socket) do
    service = socket.assigns.service

    attrs = Map.put(params, "service_id", service.id)

    case Services.create_env_var(attrs) do
      {:ok, _} ->
        updated = Services.get_service_with_env!(service.id)

        {:noreply,
         socket
         |> assign(:env_vars, updated.environment_variables)
         |> assign(:new_env_form, new_env_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_env_form, to_form(changeset, as: :environment_variable))}
    end
  end

  def handle_event("set_domain", %{"domain" => domain}, socket) do
    service = socket.assigns.service
    domain = domain |> String.trim() |> String.downcase()
    domain = if domain == "", do: nil, else: domain

    case Services.update_service(service, %{domain: domain}) do
      {:ok, updated} ->
        # If Caddy is enabled and service is running, sync the route
        if updated.domain && updated.status == "running" do
          upstream = Caddy.upstream_from_port_mappings(updated.port_mappings)
          if upstream, do: Caddy.upsert_route(updated.domain, upstream)
        end

        # If domain was removed and Caddy is enabled, remove the route
        if is_nil(domain) && service.domain do
          Caddy.remove_route(service.domain)
        end

        {:noreply,
         socket
         |> assign(:service, updated)
         |> assign(:domain_form, to_form(%{"domain" => updated.domain || ""}))
         |> put_flash(:info, if(domain, do: "Domain set to #{domain}.", else: "Domain removed."))}

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
        {:noreply, put_flash(socket, :error, "Invalid domain: #{inspect(errors[:domain])}")}
    end
  end

  def handle_event("remove_domain", _params, socket) do
    service = socket.assigns.service
    old_domain = service.domain

    {:ok, updated} = Services.update_service(service, %{domain: nil})

    if old_domain, do: Caddy.remove_route(old_domain)

    {:noreply,
     socket
     |> assign(:service, updated)
     |> assign(:domain_form, to_form(%{"domain" => ""}))
     |> put_flash(:info, "Domain removed.")}
  end

  def handle_event("delete_env", %{"id" => id}, socket) do
    env_var = Services.get_env_var!(id)
    Services.delete_env_var(env_var)

    updated = Services.get_service_with_env!(socket.assigns.service.id)
    {:noreply, assign(socket, :env_vars, updated.environment_variables)}
  end

  @impl true
  def handle_info({:status_update, unit_statuses}, socket) do
    service = socket.assigns.service

    if service.unit_name do
      new_status =
        case Map.get(unit_statuses, service.unit_name) do
          "active" -> "running"
          "failed" -> "failed"
          "inactive" -> "stopped"
          _ -> service.status
        end

      if new_status != service.status do
        {:ok, updated} = Services.update_service_status(service, new_status)
        {:noreply, assign(socket, :service, Map.put(service, :status, updated.status))}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp new_env_form do
    to_form(EnvironmentVariable.changeset(%EnvironmentVariable{}, %{}), as: :environment_variable)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8 max-w-5xl mx-auto">
      <%!-- Header --%>
      <div class="flex items-start justify-between mb-6">
        <div>
          <div class="flex items-center gap-3 mb-1">
            <.link href={~p"/services"} class="text-gray-500 hover:text-white text-sm">
              Services
            </.link>
            <span class="text-gray-700">/</span>
            <span class="text-white text-sm font-medium"><%= @service.name %></span>
          </div>
          <div class="flex items-center gap-3">
            <h1 class="text-2xl font-bold text-white"><%= @service.name %></h1>
            <.status_badge status={@service.status} />
          </div>
          <p class="text-gray-400 text-sm mt-1 font-mono"><%= @service.image %></p>
        </div>

        <%!-- Action buttons --%>
        <div class="flex items-center gap-2">
          <.link
            href={~p"/services/#{@service.id}/logs"}
            class="text-sm text-gray-400 hover:text-white border border-gray-700 hover:border-gray-600 px-3 py-1.5 rounded-lg transition-colors"
          >
            Logs
          </.link>

          <button
            phx-click="start"
            disabled={@action_loading != nil or @service.status == "running"}
            class="text-sm text-gray-300 border border-gray-700 hover:border-gray-600 hover:text-white px-3 py-1.5 rounded-lg transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Start
          </button>

          <button
            phx-click="stop"
            disabled={@action_loading != nil or @service.status == "stopped"}
            class="text-sm text-gray-300 border border-gray-700 hover:border-gray-600 hover:text-white px-3 py-1.5 rounded-lg transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Stop
          </button>

          <button
            phx-click="restart"
            disabled={@action_loading != nil}
            class="text-sm text-gray-300 border border-gray-700 hover:border-gray-600 hover:text-white px-3 py-1.5 rounded-lg transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
          >
            Restart
          </button>

          <button
            phx-click="deploy"
            disabled={@action_loading != nil}
            class="bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white text-sm font-medium px-4 py-1.5 rounded-lg transition-colors"
          >
            <%= if @action_loading == :deploy, do: "Deploying…", else: "Deploy" %>
          </button>
        </div>
      </div>

      <%!-- Info grid --%>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-8">
        <.info_card label="Restart policy" value={@service.restart_policy} />
        <.info_card label="CPU limit" value={@service.resource_cpu || "—"} />
        <.info_card label="Memory limit" value={@service.resource_mem || "—"} />
        <.info_card label="Unit name" value={@service.unit_name || "not deployed"} mono={true} />
      </div>

      <%!-- Domain / Caddy --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl p-5 mb-8">
        <div class="flex items-center justify-between mb-3">
          <div>
            <h3 class="text-sm font-semibold text-white">Caddy reverse proxy</h3>
            <p class="text-xs text-gray-500 mt-0.5">Set a domain and Quadman will register an HTTPS route in Caddy on next deploy.</p>
          </div>
          <%= if @service.domain do %>
            <div class="flex items-center gap-2">
              <span class="text-sm text-indigo-400 font-mono"><%= @service.domain %></span>
              <button phx-click="remove_domain" class="text-xs text-red-500 hover:text-red-400">Remove</button>
            </div>
          <% end %>
        </div>

        <form phx-submit="set_domain" class="flex items-start gap-2">
          <input
            type="text"
            name="domain"
            value={@domain_form[:domain].value}
            placeholder="app.example.com"
            class="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-indigo-500"
          />
          <button type="submit" class="bg-gray-700 hover:bg-gray-600 text-white text-sm px-4 py-2 rounded-lg whitespace-nowrap">
            <%= if @service.domain, do: "Update domain", else: "Set domain" %>
          </button>
        </form>
      </div>

      <%!-- Port mappings & Volumes --%>
      <div class="grid grid-cols-2 gap-4 mb-8">
        <div class="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <h3 class="text-sm font-semibold text-white mb-3">Port Mappings</h3>
          <%= if @service.port_mappings == [] do %>
            <p class="text-gray-500 text-sm">None</p>
          <% else %>
            <ul class="space-y-1">
              <%= for p <- @service.port_mappings do %>
                <li class="text-sm font-mono text-gray-300"><%= p %></li>
              <% end %>
            </ul>
          <% end %>
        </div>

        <div class="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <h3 class="text-sm font-semibold text-white mb-3">Volumes</h3>
          <%= if @service.volumes == [] do %>
            <p class="text-gray-500 text-sm">None</p>
          <% else %>
            <ul class="space-y-1">
              <%= for v <- @service.volumes do %>
                <li class="text-sm font-mono text-gray-300"><%= v %></li>
              <% end %>
            </ul>
          <% end %>
        </div>
      </div>

      <%!-- Environment variables --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl mb-8">
        <div class="px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">Environment Variables</h2>
        </div>

        <div class="divide-y divide-gray-800">
          <%= for env <- @env_vars do %>
            <div class="flex items-center justify-between px-5 py-2.5">
              <div class="flex items-center gap-4 flex-1 min-w-0">
                <span class="text-sm font-mono text-gray-200 shrink-0"><%= env.key %></span>
                <span class="text-sm font-mono text-gray-500 truncate">
                  <%= if env.is_secret, do: "••••••••", else: env.value %>
                </span>
                <%= if env.is_secret do %>
                  <span class="text-xs text-yellow-500 bg-yellow-900/30 px-1.5 py-0.5 rounded">secret</span>
                <% end %>
              </div>
              <button
                phx-click="delete_env"
                phx-value-id={env.id}
                class="text-xs text-red-500 hover:text-red-400 ml-4"
              >
                Remove
              </button>
            </div>
          <% end %>

          <div class="px-5 py-3">
            <.form for={@new_env_form} phx-change="validate_env" phx-submit="add_env">
              <div class="flex items-start gap-2">
                <.input field={@new_env_form[:key]} placeholder="KEY" class="bg-gray-800 border-gray-700 text-white font-mono text-sm" />
                <.input field={@new_env_form[:value]} placeholder="value" class="bg-gray-800 border-gray-700 text-white font-mono text-sm" />
                <label class="flex items-center gap-1.5 text-xs text-gray-400 mt-2 whitespace-nowrap">
                  <input type="checkbox" name="environment_variable[is_secret]" value="true" class="rounded" />
                  Secret
                </label>
                <button type="submit" class="text-sm bg-gray-700 hover:bg-gray-600 text-white px-3 py-2 rounded-lg whitespace-nowrap">
                  + Add
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>

      <%!-- Recent deployments --%>
      <div class="bg-gray-900 border border-gray-800 rounded-xl">
        <div class="px-5 py-4 border-b border-gray-800">
          <h2 class="font-semibold text-white">Recent Deployments</h2>
        </div>
        <div class="divide-y divide-gray-800">
          <%= for d <- @deployments do %>
            <div class="flex items-center justify-between px-5 py-3">
              <div class="flex items-center gap-3">
                <.status_badge status={d.status} />
                <span class="text-xs font-mono text-gray-500"><%= d.image_digest && String.slice(d.image_digest, 0..15) || "—" %></span>
              </div>
              <.link href={~p"/deployments/#{d.id}"} class="text-xs text-indigo-400 hover:text-indigo-300">
                View logs &rarr;
              </.link>
            </div>
          <% end %>
          <%= if @deployments == [] do %>
            <div class="px-5 py-6 text-center text-gray-500 text-sm">No deployments yet.</div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp info_card(assigns) do
    assigns = assign_new(assigns, :mono, fn -> false end)

    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-xl px-4 py-3">
      <div class="text-xs text-gray-500 mb-1"><%= @label %></div>
      <div class={["text-sm text-white truncate", if(@mono, do: "font-mono")]}><%= @value %></div>
    </div>
    """
  end
end
