defmodule CodeMySpec.Agents.Transport.Harness do
  @moduledoc """
  Asks the working copy's channel to end an agent's process group.

  `HarnessRegistry` holds a live process per connected copy, and that process is
  the channel. Sending the request to it means the thing proving the machine is
  reachable and the thing the request goes to are the same pid — the argument
  `Analysis` already makes for dispatching runs this way.
  """

  @behaviour CodeMySpec.Agents.Transport

  require Logger

  alias CodeMySpec.Agents.Agent
  alias CodeMySpecWeb.HarnessRegistry

  @impl true
  def start_agent(working_copy_id, %Agent{} = agent, timeout) do
    case holder(working_copy_id) do
      {:ok, pid} -> call(pid, {:start_agent, launch_request(agent)}, timeout, :start_timed_out)
      :none -> unreachable(working_copy_id, agent, "start")
    end
  end

  @impl true
  def stop_agent(working_copy_id, %Agent{} = agent, timeout) do
    case holder(working_copy_id) do
      {:ok, pid} ->
        call(pid, {:stop_agent, stop_request(agent, timeout)}, timeout, :stop_timed_out)

      :none ->
        unreachable(working_copy_id, agent, "stop")
    end
  end

  # The channel holding this copy, or nothing.
  #
  # `Registry.lookup/2` raises when the registry itself is not running, and that
  # is not an error the caller can act on differently: "no harness registered"
  # and "no registry to ask" are the same answer — nobody is reachable. Anything
  # that boots without the data plane is in the second case, which is every spex
  # run and the light harness itself.
  defp holder(working_copy_id) do
    case Registry.lookup(HarnessRegistry, to_string(working_copy_id)) do
      [{pid, _}] -> {:ok, pid}
      [] -> :none
    end
  rescue
    ArgumentError -> :none
  end

  defp call(pid, message, timeout, timeout_reason) do
    GenServer.call(pid, message, timeout + 5_000)
  catch
    :exit, {:timeout, _} ->
      # Distinct from "no harness". The machine is there and did not finish, so
      # for a stop the process may well still be running — and reporting one
      # here would be the lie the whole story is about.
      {:error, timeout_reason}
  end

  # What the far side needs to decide a command and where to run it. Not a
  # command: the machine knows what is installed on it and the server does not.
  defp launch_request(%Agent{} = agent) do
    %{
      "agent_id" => agent.id,
      "engine" => to_string(agent.engine),
      "provider" => agent.provider,
      "config_dir" => agent.config_dir,
      "working_copy" => agent.working_copy,
      "role" => agent.role
    }
  end

  defp stop_request(%Agent{} = agent, timeout) do
    %{
      "agent_id" => agent.id,
      "os_pid" => agent.os_pid,
      "os_boot_id" => agent.os_boot_id,
      "grace_ms" => timeout
    }
  end

  # Nothing registered under that id. Deliberately not treated as "already
  # stopped": the process is on a machine we cannot currently reach, so it is
  # very likely still running and still spending. The operator is told which of
  # the two it is, because the remedies differ entirely.
  defp unreachable(working_copy_id, agent, verb) do
    Logger.warning(
      "[Agents] cannot #{verb} agent #{agent.id}: nothing registered for working copy " <>
        "#{working_copy_id}. That machine is not reachable from this server, so nothing " <>
        "was asked of it — for a stop, the process group #{inspect(agent.os_pid)} may " <>
        "still be running."
    )

    {:error, :harness_not_connected}
  end
end
