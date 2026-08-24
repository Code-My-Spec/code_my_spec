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
  alias CodeMySpec.Analysis

  @impl true
  def start_agent(working_copy_id, %Agent{} = agent, timeout) do
    case holder(working_copy_id) do
      {:ok, pid} -> call(pid, {:start_agent, launch_request(agent)}, timeout, :start_timed_out)
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

  # What the far side needs to decide a command and where to run it. Not a
  # command: the machine knows what is installed on it and the server does not.
  # `config_dir` used to be here: a path to a directory the *server* wrote,
  # which the machine then read. That only worked when the two were the same
  # box. The credential travels instead, and the machine materialises whatever
  # its provider needs.
  defp launch_request(%Agent{} = agent) do
    %{
      "agent_id" => agent.id,
      "engine" => to_string(agent.engine),
      "provider" => agent.provider,
      "working_copy" => agent.working_copy,
      "role" => agent.role
    }
    |> Map.merge(credential_fields(agent.credential))
  end

  # Only the field the named provider actually uses. An api-key provider has no
  # use for a token pair, and sending both would put a subscription on the wire
  # for a request that did not need it.
  defp credential_fields(%{"type" => "api_key", "key" => key}), do: %{"api_key" => key}
  defp credential_fields(_credential), do: %{}

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
