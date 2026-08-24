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
  def stop_agent(working_copy_id, %Agent{} = agent, timeout) do
    case Registry.lookup(HarnessRegistry, to_string(working_copy_id)) do
      [{pid, _}] -> call(pid, agent, timeout)
      [] -> unreachable(working_copy_id, agent)
    end
  end

  defp call(pid, agent, timeout) do
    GenServer.call(pid, {:stop_agent, request(agent, timeout)}, timeout + 5_000)
  catch
    :exit, {:timeout, _} ->
      # Distinct from "no harness". The machine is there and did not finish, so
      # the process may well still be running — and reporting a stop here would
      # be the lie the whole story is about.
      {:error, :stop_timed_out}
  end

  defp request(%Agent{} = agent, timeout) do
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
  defp unreachable(working_copy_id, agent) do
    Logger.warning(
      "[Agents] cannot stop agent #{agent.id}: nothing registered for working copy " <>
        "#{working_copy_id}. Its process group #{inspect(agent.os_pid)} is on a machine " <>
        "this server cannot reach, so it has not been stopped and may still be running."
    )

    {:error, :harness_not_connected}
  end
end
