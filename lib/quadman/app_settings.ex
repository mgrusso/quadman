defmodule Quadman.AppSettings do
  alias Quadman.Repo

  @primary_key {:key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :value, :string
    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:value])
    |> validate_required([:value])
  end

  @doc "Returns the stored value for `key`, or `default` if not set."
  def get(key, default \\ nil) do
    case Repo.get(__MODULE__, key) do
      nil -> default
      setting -> setting.value
    end
  end

  @doc "Upserts a key/value pair."
  def put(key, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert(
      %__MODULE__{key: key, value: to_string(value), inserted_at: now, updated_at: now},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end
end
