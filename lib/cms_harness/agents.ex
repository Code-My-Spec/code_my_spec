defmodule CmsHarness.Agents do
  @moduledoc """
  Turning "start a Pi agent on this copy" into a process on this machine.

  The server knows the engine, the provider, the config directory and the
  working copy. It does not know what is installed here, and cannot — a box
  with no `pi` on its PATH is a fact only that box has. So the command is
  decided here and the failure is named here.

  ## Why the config directory is passed rather than found

  `PI_CODING_AGENT_DIR` overrides `~/.pi/agent` wholesale — auth, models,
  settings, extensions. That is the seam story 956 chose for tenant isolation:
  the cloud box is multi-tenant, so a machine-wide auth file would put one
  tenant's subscription in reach of another. `Agents.PiConfig` mints one
  directory per agent, outside the working copy, and this is what points the
  process at it.

  ## Why the working copy is the cwd

  An agent works in a checkout, and every tool it runs — `git`, `mix`, the
  analyzers — resolves relative to where it started. Starting it anywhere else
  produces an agent that reads the right instructions and edits the wrong tree.
  """

  require Logger

  alias CmsHarness.Agents.Runner

  @doc """
  Launch the agent this request describes, in its own process group.

  Answers `{:ok, %{pgid: group_id, boot_id: boot}}` — `Runner`'s handle, the
  pair that has to travel together — or `{:error, reason}` naming what this
  machine could not do.

  It said `%{os_pid:, os_boot_id:}` here for as long as this function existed,
  which are the names the *wire* uses, not the ones it returns.
  `ChannelClient.encode_start_result/1` believed the docs and matched those
  names against the handle, so it matched nothing and every start crashed the
  channel. The translation belongs in the encoder; this says what it hands over.
  """
  @spec launch(map()) ::
          {:ok, %{pgid: pos_integer(), boot_id: String.t()}} | {:error, atom()}
  def launch(%{"engine" => engine} = request) do
    with {:ok, command, args} <- command_for(engine),
         :ok <- working_copy_exists(request["working_copy"]) do
      Runner.start(command, args, cd: request["working_copy"], env: env_for(request))
    end
  end

  def launch(_request), do: {:error, :no_engine}

  # Named rather than discovered from a failed spawn. "pi is not installed on
  # this machine" and "pi started and immediately died" want completely
  # different things from whoever reads it, and a spawn failure alone cannot
  # tell them apart.
  defp command_for("pi") do
    case System.find_executable("pi") do
      nil -> {:error, :pi_not_installed}
      pi -> {:ok, pi, ["--mode", "json"]}
    end
  end

  defp command_for("claude_code") do
    case System.find_executable("claude") do
      nil -> {:error, :claude_not_installed}
      claude -> {:ok, claude, []}
    end
  end

  defp command_for(other) do
    Logger.warning(
      "[CmsHarness] asked to start engine #{inspect(other)}, which this harness " <>
        "does not know how to run"
    )

    {:error, :unknown_engine}
  end

  # A checkout that is not there cannot be worked in, and starting an agent with
  # a missing cwd fails deep inside the spawn with a message about the shell.
  # This is the same question `WorkingCopyReporter` asks, answered before rather
  # than after spending a process on it.
  defp working_copy_exists(nil), do: {:error, :no_working_copy}

  defp working_copy_exists(root) do
    case File.dir?(root) do
      true -> :ok
      false -> {:error, :working_copy_missing}
    end
  end

  # Only what the agent needs, and the config directory is the point of it.
  # Inherited environment carries whatever the harness was started with, which
  # on a multi-tenant box is somebody else's business.
  defp env_for(request) do
    [{"PI_CODING_AGENT_DIR", request["config_dir"]}]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
