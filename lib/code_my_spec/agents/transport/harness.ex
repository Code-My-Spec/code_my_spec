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
  alias CodeMySpec.Agents.LaunchRequest
  alias CodeMySpec.Analysis

  @impl true
  @doc """
  Ask a machine to make a working copy.

  Not part of the `Transport` behaviour: every callback there names an agent and
  a checkout that exists, and this asks for a checkout to exist. It lives here
  because the mechanism is identical — find the pid holding a channel, call it,
  let the reply come back correlated by `ref`.

  `host_holder/1` rather than `holder/1`: there is no id yet, so the address is
  a machine, and any connected copy of the project stands for the machine it is
  on.
  """
  @spec create_working_copy([String.t()], map(), timeout()) ::
          {:ok, %{root: String.t(), working_copy_id: String.t()}} | {:error, term()}
  def create_working_copy(candidate_ids, request, timeout) do
    case Analysis.host_holder(candidate_ids) do
      {:ok, pid, _root} ->
        call(pid, {:create_working_copy, request}, timeout, :create_timed_out)

      :none ->
        {:error, :no_harness}
    end
  end

  @impl true
  def start_agent(working_copy_id, %Agent{} = agent, timeout) do
    case holder(working_copy_id) do
      {:ok, pid} -> call(pid, {:start_agent, LaunchRequest.for(agent)}, timeout, :start_timed_out)
      :none -> unreachable(working_copy_id, agent, "start")
    end
  end

  @impl true
  def message_agent(working_copy_id, %Agent{} = agent, message, timeout) do
    case holder(working_copy_id) do
      {:ok, pid} ->
        call(
          pid,
          {:message_agent, %{"agent_id" => agent.id, "message" => message, "timeout" => timeout}},
          timeout,
          :message_timed_out
        )

      :none ->
        unreachable(working_copy_id, agent, "message")
    end
  end

  @impl true
  def dispatch_message(working_copy_id, %Agent{} = agent, ref, message, timeout) do
    case holder(working_copy_id) do
      {:ok, pid} ->
        call(
          pid,
          {:dispatch_message,
           %{"agent_id" => agent.id, "message_ref" => ref, "message" => message}},
          timeout,
          :message_timed_out
        )

      :none ->
        unreachable(working_copy_id, agent, "message")
    end
  end

  @impl true
  def withdraw_message(working_copy_id, %Agent{} = agent, ref, timeout) do
    case holder(working_copy_id) do
      {:ok, pid} ->
        call(
          pid,
          {:withdraw_message, %{"agent_id" => agent.id, "message_ref" => ref}},
          timeout,
          :withdraw_timed_out
        )

      :none ->
        unreachable(working_copy_id, agent, "withdraw a message from")
    end
  end

  @impl true
  def call_machine_tool(working_copy_id, tool, arguments, timeout) do
    case holder(working_copy_id) do
      {:ok, pid} ->
        call(
          pid,
          # The budget travels with the call. Every hop between here and Chrome
          # used to supply its own thirty seconds, so a caller who asked for a
          # minute got half of one from whichever hop was strictest — and no
          # part of the answer said which. The machine gets told what it has.
          {:call_machine_tool, %{"tool" => tool, "arguments" => arguments, "timeout" => timeout}},
          timeout,
          :machine_tool_timed_out
        )

      # Different from a tool that ran and failed, and it gets a different
      # sentence: the browser is on a machine that is not connected, which the
      # agent cannot fix by calling something else.
      :none ->
        {:error, :harness_unreachable}
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
  # Through `Analysis.executor_holder/1` rather than a `Registry.lookup/2` of
  # its own, so there is one definition of "which process holds this copy".
  #
  # The second definition was wrong and could not be seen to be. It aliased
  # `CodeMySpecWeb.HarnessRegistry`, which is not a module anywhere — the real
  # one is `CodeMySpec.Analysis.HarnessRegistry` — so the lookup raised on every
  # call, and a `rescue ArgumentError -> :none` I had added turned that into
  # `:harness_not_connected`. Every start and every stop reported the machine
  # unreachable in every environment, including with a harness connected and
  # reconciling that exact copy a second earlier.
  #
  # The rescue was added to quiet eleven spex failing with "unknown registry",
  # diagnosed as "the registry is not running in test" without checking that the
  # module existed. It converted a loud, correct error into a silent wrong
  # answer, and the suite stayed green because every spex here swaps the
  # transport for an in-process one — so this module was never exercised.
  defp holder(working_copy_id) do
    case Analysis.executor_holder(working_copy_id) do
      {:ok, pid, _instance} -> {:ok, pid}
      :error -> :none
    end
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

  # The id is the whole handle. It used to carry a process group id and the boot
  # it belonged to, because a group number outlives its group and gets reused —
  # a supervised process has no such problem.
  defp stop_request(%Agent{} = agent, timeout) do
    %{"agent_id" => agent.id, "grace_ms" => timeout}
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
