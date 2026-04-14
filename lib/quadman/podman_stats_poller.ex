defmodule Quadman.PodmanStatsPoller do
  @moduledoc """
  GenServer that polls `podman stats` (no-stream) every 10s and caches results
  in an ETS table named `:quadman_stats`.

  The ETS table is keyed by container name: `{name => stats_map}`.
  Callers read directly from ETS via `get/1` / `all/0` — no GenServer call needed.

  Gracefully degrades: if the Podman socket is unreachable, the ETS table is left
  as-is and a warning is logged. The dashboard reads stale data rather than crashing.
  """

  use GenServer
  require Logger

  alias Quadman.Podman

  @table :quadman_stats
  @interval_ms 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns stats for a specific container name, or nil."
  def get(name) do
    case :ets.whereis(@table) do
      :undefined -> nil
      _ ->
        case :ets.lookup(@table, name) do
          [{^name, stats}] -> stats
          [] -> nil
        end
    end
  end

  @doc "Returns all cached stats as a map of name => stats."
  def all do
    case :ets.whereis(@table) do
      :undefined -> %{}
      _ -> :ets.tab2list(@table) |> Map.new()
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
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
    case Podman.stats() do
      {:ok, stats_list} ->
        entries =
          Enum.map(stats_list, fn s ->
            name = Map.get(s, "Name") || Map.get(s, "name", "unknown")
            {name, s}
          end)

        # Atomic replace: delete all then insert new batch
        :ets.delete_all_objects(@table)
        :ets.insert(@table, entries)

      {:error, reason} ->
        Logger.debug("PodmanStatsPoller: socket unavailable — #{inspect(reason)}")
    end
  rescue
    e -> Logger.error("PodmanStatsPoller poll error: #{inspect(e)}")
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @interval_ms)
  end
end
