defmodule Quadman.Quadlets do
  @moduledoc """
  Generates and writes Quadlet .container (and future .pod / .network) files.

  Templates are EEx strings in this module for easy unit testing.
  """

  alias Quadman.Services.Service

  @doc """
  Renders the .container Quadlet file content for a service.
  `env_vars` is a list of `%EnvironmentVariable{}`.
  `stack_name` is nil for standalone services, or the pod name for pod containers.
  """
  def render_container(%Service{} = service, env_vars, stack_name \\ nil) do
    public_env = Enum.reject(env_vars, & &1.is_secret)
    secret_env = Enum.filter(env_vars, & &1.is_secret)
    secret_file = secret_env_path(service.name)

    EEx.eval_string(
      container_template(),
      assigns: [
        service: service,
        public_env: public_env,
        has_secrets: secret_env != [],
        secret_file: secret_file,
        stack_name: stack_name
      ]
    )
  end

  @doc """
  Writes the .container file to the Quadlet directory.
  Returns `{:ok, path}` or `{:error, reason}`.
  """
  def write_container(%Service{} = service, env_vars, stack_name \\ nil) do
    content = render_container(service, env_vars, stack_name)
    path = container_path(service.name)

    dir = quadlet_dir()

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      {:ok, path}
    end
  end

  @doc """
  Writes the secrets env file (mode 0600) for a service.
  Returns `:ok` or `{:error, reason}`.
  """
  def write_secrets(%Service{} = service, env_vars) do
    secret_env = Enum.filter(env_vars, & &1.is_secret)

    if secret_env == [] do
      :ok
    else
      path = secret_env_path(service.name)
      dir = secret_dir()
      content = Enum.map_join(secret_env, "\n", fn e -> "#{e.key}=#{e.value}" end) <> "\n"

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(path, content),
           :ok <- File.chmod(path, 0o600) do
        :ok
      end
    end
  end

  @doc """
  Returns the derived systemd unit name for a service (as Quadlet generates it).
  """
  def unit_name(service_name), do: "#{service_name}.service"

  defp quadlet_dir do
    Application.get_env(:quadman, :quadlet_dir, Path.expand("~/.config/containers/systemd"))
  end

  defp secret_dir do
    Application.get_env(:quadman, :quadlet_secret_dir, Path.expand("~/.config/quadman/secrets"))
  end

  defp container_path(name), do: Path.join(quadlet_dir(), "#{name}.container")
  defp secret_env_path(name), do: Path.join(secret_dir(), "#{name}.env")

  # ---------------------------------------------------------------------------
  # Template
  # ---------------------------------------------------------------------------

  defp container_template do
    """
    [Unit]
    Description=<%= @service.name %> (managed by Quadman)
    After=network-online.target

    [Container]
    Image=<%= @service.image %>
    <%= for mapping <- @service.port_mappings do %>PublishPort=<%= mapping %>
    <% end %><%= for vol <- @service.volumes do %>Volume=<%= vol %>
    <% end %><%= for env <- @public_env do %>Environment=<%= env.key %>=<%= env.value %>
    <% end %><%= if @has_secrets do %>EnvironmentFile=<%= @secret_file %>
    <% end %><%= if @stack_name do %>Pod=<%= @stack_name %>.pod
    <% end %>AutoUpdate=registry

    [Service]
    Restart=<%= @service.restart_policy %><%= if @service.resource_cpu do %>
    CPUQuota=<%= @service.resource_cpu %><% end %><%= if @service.resource_mem do %>
    MemoryMax=<%= @service.resource_mem %><% end %>

    [Install]
    WantedBy=default.target
    """
  end
end
