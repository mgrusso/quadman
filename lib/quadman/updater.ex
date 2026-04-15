defmodule Quadman.Updater do
  @moduledoc """
  Handles version reporting and in-place self-updates from GitHub Releases.

  Update flow:
    1. Download the release tarball to /tmp
    2. Extract it over the current install directory (BEAM supports hot-swapping)
    3. Call `sudo systemctl restart quadman` — requires the sudoers rule installed by install.sh:
         quadman ALL=(ALL) NOPASSWD: <systemctl_path> restart quadman
    4. systemd kills the current process and starts the new binary
  """

  require Logger

  @github_repo "mgrusso/quadman"
  @tarball_name "quadman-linux-x86_64.tar.gz"

  # ---------------------------------------------------------------------------
  # Version info
  # ---------------------------------------------------------------------------

  @doc "Returns the running application version string, e.g. \"0.3.0\"."
  def current_version do
    Application.spec(:quadman, :vsn) |> to_string()
  end

  # ---------------------------------------------------------------------------
  # Update check
  # ---------------------------------------------------------------------------

  @doc """
  Fetches the latest release from GitHub.
  Returns `{:ok, %{version: \"0.3.1\", tag: \"v0.3.1\", tarball_url: \"...\", notes: \"...\"}}` or `{:error, reason}`.
  """
  def check_latest do
    url = "https://api.github.com/repos/#{@github_repo}/releases/latest"

    case Req.get(url, headers: [{"user-agent", "quadman/#{current_version()}"}]) do
      {:ok, %{status: 200, body: body}} ->
        tag = body["tag_name"] || ""
        version = String.trim_leading(tag, "v")
        tarball_url = "https://github.com/#{@github_repo}/releases/download/#{tag}/#{@tarball_name}"

        {:ok,
         %{
           version: version,
           tag: tag,
           tarball_url: tarball_url,
           notes: truncate_notes(body["body"] || "")
         }}

      {:ok, %{status: status}} ->
        {:error, "GitHub API returned HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "True if `latest_version` is newer than the running version."
  def update_available?(latest_version) do
    case Version.compare(latest_version, current_version()) do
      :gt -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Update
  # ---------------------------------------------------------------------------

  @doc """
  Downloads and applies the update, then restarts the service.
  This call will not return on success — the process is killed by the restart.
  Returns `{:error, reason}` if the download or extraction fails.
  """
  def download_and_apply(tarball_url) do
    tmp = "/tmp/quadman-update-#{System.unique_integer([:positive])}.tar.gz"
    install_dir = install_dir()

    Logger.info("Updater: downloading #{tarball_url}")

    with :ok <- download(tarball_url, tmp),
         :ok <- extract(tmp, install_dir) do
      File.rm(tmp)
      Logger.info("Updater: extracted to #{install_dir}, restarting service")
      restart_service()
    else
      {:error, reason} = err ->
        File.rm(tmp)
        Logger.error("Updater: failed — #{inspect(reason)}")
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp download(url, dest) do
    case Req.get(url,
           headers: [{"user-agent", "quadman/#{current_version()}"}],
           into: File.stream!(dest),
           receive_timeout: 120_000,
           redirect: true
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, "download failed: HTTP #{s}"}
      {:error, reason} -> {:error, "download error: #{inspect(reason)}"}
    end
  end

  defp extract(tarball, dest) do
    case System.cmd("tar", ["-xzf", tarball, "-C", dest], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "tar exited #{code}: #{String.trim(output)}"}
    end
  end

  defp restart_service do
    # Sudoers rule (added by install.sh) allows this without a password:
    #   quadman ALL=(ALL) NOPASSWD: <systemctl> restart quadman
    System.cmd("sudo", ["systemctl", "restart", "quadman"], stderr_to_stdout: true)
    # If we reach here the restart didn't fire — return ok anyway;
    # the LiveView disconnect will confirm it when it does.
    :ok
  end

  defp install_dir do
    # In a release, :code.root_dir() is the release root (e.g. /opt/quadman)
    :code.root_dir() |> to_string()
  end

  defp truncate_notes(notes) do
    if String.length(notes) > 400 do
      String.slice(notes, 0, 400) <> "…"
    else
      notes
    end
  end
end
