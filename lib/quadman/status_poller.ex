defmodule Quadman.StatusPoller do
  @moduledoc """
  GenServer that polls `systemctl is-active` for all known service units every 30s,
  updates DB statuses, and broadcasts `{:status_update, unit_statuses}` on the
  "services:status" PubSub topic.

  A single `systemctl is-active u1 u2 u3` invocation is used — avoids N process spawns.
  """

  use GenServer
  require Logger

  alias Quadman.{Services, Systemd}

  @interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll()
    schedule_poll()
    {:noreply, state}
  end

  defp poll do
    services = Services.list_services()
    units = services |> Enum.map(& &1.unit_name) |> Enum.reject(&is_nil/1)

    if units != [] do
      case Systemd.is_active_many(units) do
        {:ok, unit_statuses} ->
          Services.refresh_service_statuses(unit_statuses)

          Phoenix.PubSub.broadcast(
            Quadman.PubSub,
            "services:status",
            {:status_update, unit_statuses}
          )

        {:error, reason} ->
          Logger.warning("StatusPoller: is_active_many failed: #{inspect(reason)}")
      end
    end
  rescue
    e -> Logger.error("StatusPoller poll error: #{inspect(e)}")
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @interval_ms)
  end
end
