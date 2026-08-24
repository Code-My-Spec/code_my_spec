defmodule CodeMySpecSpex.AgentProcessHelpers do
  @moduledoc """
  A real agent for story 1023's criteria to stop.

  The criteria are about whether an agent stops spending, so an agent that is
  not really running proves nothing about them. Three shipped instances of the
  same defect on this project all passed tests that never had one.

  ## What changed, and what did not

  It used to start `sleep` in its own process group and assert against `ps`,
  because an agent was a detached OS process and the only honest question was
  whether that process was still there. An agent is a supervised process now, so
  the question is whether *it* is still there — but the discipline is the same:
  start a real one, stop it through the operator's own surface, and assert it is
  gone rather than that a row says so.

  No provider is ever contacted. `Alloy.Agent.Server` reaches one only when
  something chats to it, and nothing here does, so these run for free and
  without a network.
  """

  import ExUnit.Assertions

  alias CmsHarnessTest.Machine
  alias CodeMySpecTest.UnreachableMachine

  @doc """
  Start a real agent on this machine under `agent_id`, in a scratch checkout.

  Returns the id, which is the whole handle — there is no process group id and
  no boot id, because there is no foreign process to name.
  """
  @spec start_agent(String.t(), keyword()) :: String.t()
  def start_agent(agent_id, opts \\ []) do
    Machine.ensure_supervisor()

    copy = Keyword.get_lazy(opts, :working_copy, &scratch_copy/0)

    assert {:ok, _} = Machine.start_agent(agent_id, copy, Keyword.get(opts, :on_stop)),
           "the premise is an agent that is actually running; without one this " <>
             "criterion asserts nothing about spending"

    ExUnit.Callbacks.on_exit(fn -> Machine.stop_agent(agent_id) end)

    agent_id
  end

  @doc """
  Bring one agent back, the way a harness does after a restart.

  The channel client loops over what the server sent and launches each through
  the same call a fresh start uses. This is one entry of that loop, so the
  refusals a restore inherits — a checkout that is gone, a provider nobody knows
  — are the real ones rather than a second implementation of them.
  """
  @spec restore_agent(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def restore_agent(agent_id, working_copy) do
    Machine.ensure_supervisor()
    Machine.start_agent(agent_id, working_copy)
  end

  @doc """
  End an agent's process without changing what the record says it should be.

  What a harness restart does: the process goes, the intent does not. Not the
  same as stopping an agent, which is a decision and changes the desired state
  — and telling those two apart is the whole of criteria 2890 and 2891.
  """
  @spec stop_agent_process(String.t()) :: :ok
  def stop_agent_process(agent_id) do
    Machine.stop_agent(agent_id)
    :ok
  end

  @doc "Whether this machine is running that agent right now."
  @spec running?(String.t()) :: boolean()
  defdelegate running?(agent_id), to: Machine

  @doc """
  Put the agent's machine out of reach for this scenario.

  Restored afterwards, because the transport is application-wide: leaving it
  swapped would make every later spex in the run talk to a machine that refuses
  everything, and they would fail for a reason that has nothing to do with them.
  """
  @spec machine_out_of_reach() :: :ok
  def machine_out_of_reach do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, UnreachableMachine)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :agent_transport, previous)
    end)

    :ok
  end

  # Somewhere disposable for the agent to be pointed at. It has to exist:
  # starting an agent on a checkout that is not there is refused, which is its
  # own criterion.
  defp scratch_copy do
    dir = CodeMySpec.TempFile.dir("spex_1023_agent")
    File.mkdir_p!(dir)
    dir
  end
end
