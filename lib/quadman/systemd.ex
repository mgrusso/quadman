defmodule Quadman.Systemd do
  @moduledoc """
  Wrapper around `systemctl` for managing Quadlet-generated units.

  The `scope` config key (`:user` or `:system`) controls whether `--user` is passed.
  On macOS dev, configure `systemd_adapter: Quadman.Systemd.Stub` to skip real invocations.
  """

  @callback daemon_reload() :: :ok | {:error, String.t()}
  @callback start(unit :: String.t()) :: :ok | {:error, String.t()}
  @callback stop(unit :: String.t()) :: :ok | {:error, String.t()}
  @callback restart(unit :: String.t()) :: :ok | {:error, String.t()}
  @callback is_active(unit :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  @callback is_active_many(units :: [String.t()]) :: {:ok, %{String.t() => String.t()}}

  defp adapter do
    Application.get_env(:quadman, :systemd_adapter, __MODULE__.Real)
  end

  def daemon_reload, do: adapter().daemon_reload()
  def start(unit), do: adapter().start(unit)
  def stop(unit), do: adapter().stop(unit)
  def restart(unit), do: adapter().restart(unit)
  def is_active(unit), do: adapter().is_active(unit)
  def is_active_many(units), do: adapter().is_active_many(units)
end
