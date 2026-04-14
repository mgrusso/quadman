defmodule Quadman.Systemd.Stub do
  @moduledoc """
  macOS dev stub — all units are reported as active, write/reload ops are no-ops.
  Activate via: `config :quadman, systemd_adapter: Quadman.Systemd.Stub`
  """

  @behaviour Quadman.Systemd

  @impl true
  def daemon_reload do
    require Logger
    Logger.debug("[Systemd.Stub] daemon-reload (no-op)")
    :ok
  end

  @impl true
  def start(unit) do
    require Logger
    Logger.debug("[Systemd.Stub] start #{unit} (no-op)")
    :ok
  end

  @impl true
  def stop(unit) do
    require Logger
    Logger.debug("[Systemd.Stub] stop #{unit} (no-op)")
    :ok
  end

  @impl true
  def restart(unit) do
    require Logger
    Logger.debug("[Systemd.Stub] restart #{unit} (no-op)")
    :ok
  end

  @impl true
  def is_active(_unit), do: {:ok, "active"}

  @impl true
  def is_active_many(units) do
    {:ok, Map.new(units, fn u -> {u, "active"} end)}
  end
end
