defmodule Quadman.Systemd.Real do
  @behaviour Quadman.Systemd

  defp scope_args do
    case Application.get_env(:quadman, :systemd_scope, "user") do
      "user" -> ["--user"]
      "system" -> []
    end
  end

  defp systemctl(args) do
    case System.cmd("systemctl", scope_args() ++ args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, "systemctl exited #{code}: #{String.trim(output)}"}
    end
  end

  @impl true
  def daemon_reload, do: systemctl(["daemon-reload"])

  @impl true
  def start(unit), do: systemctl(["start", unit])

  @impl true
  def stop(unit), do: systemctl(["stop", unit])

  @impl true
  def restart(unit), do: systemctl(["restart", unit])

  @impl true
  def is_active(unit) do
    case System.cmd("systemctl", scope_args() ++ ["is-active", unit], stderr_to_stdout: true) do
      {output, _} -> {:ok, String.trim(output)}
    end
  end

  @impl true
  def is_active_many([]), do: {:ok, %{}}

  def is_active_many(units) do
    # Single invocation: `systemctl is-active u1 u2 u3`
    # Output is one status per line, in the same order as inputs.
    {output, _} =
      System.cmd("systemctl", scope_args() ++ ["is-active"] ++ units, stderr_to_stdout: true)

    statuses =
      output
      |> String.split("\n", trim: true)
      |> Enum.zip(units)
      |> Map.new(fn {status, unit} -> {unit, String.trim(status)} end)

    {:ok, statuses}
  end
end
