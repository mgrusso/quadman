defmodule Quadman.Services.Service do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "services" do
    field :name, :string
    field :image, :string
    field :port_mappings, {:array, :string}, default: []
    field :volumes, {:array, :string}, default: []
    field :resource_cpu, :string
    field :resource_mem, :string
    field :restart_policy, :string, default: "on-failure"
    field :quadlet_path, :string
    field :unit_name, :string
    field :status, :string, default: "stopped"
    field :domain, :string
    field :auto_update, :boolean, default: false
    field :compose_service_key, :string

    belongs_to :stack, Quadman.Stacks.Stack
    has_many :environment_variables, Quadman.Services.EnvironmentVariable
    has_many :deployments, Quadman.Deployments.Deployment

    timestamps(type: :utc_datetime)
  end

  @valid_restart_policies ~w(no on-success on-failure on-abnormal on-watchdog on-abort always)
  @valid_statuses ~w(running stopped failed unknown deploying)

  def changeset(service, attrs) do
    service
    |> cast(attrs, [:name, :image, :port_mappings, :volumes, :resource_cpu, :resource_mem,
                    :restart_policy, :quadlet_path, :unit_name, :status, :stack_id, :domain,
                    :auto_update, :compose_service_key])
    |> validate_required([:name, :image])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/, message: "must be lowercase alphanumeric, dashes, or underscores")
    |> validate_format(:domain, ~r/^[a-z0-9][a-z0-9.\-]*\.[a-z]{2,}$/, message: "must be a valid hostname")
    |> validate_inclusion(:restart_policy, @valid_restart_policies)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_volumes()
    |> unique_constraint(:name)
    |> unique_constraint(:domain)
  end

  defp validate_volumes(changeset) do
    validate_change(changeset, :volumes, fn :volumes, volumes ->
      bad =
        Enum.reject(volumes, fn mapping ->
          host = mapping |> String.split(":", parts: 3) |> List.first()

          cond do
            # Named Podman volume (no leading slash): always OK
            not String.starts_with?(host, "/") -> true
            # Absolute bind-mount path: reject if any segment is ".."
            true -> host |> Path.split() |> Enum.all?(&(&1 != ".."))
          end
        end)

      if bad == [] do
        []
      else
        [{:volumes, "contains invalid host path (path traversal not allowed): #{Enum.join(bad, ", ")}"}]
      end
    end)
  end

  def status_changeset(service, status) do
    service
    |> cast(%{status: status}, [:status])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
