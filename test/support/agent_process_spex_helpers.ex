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

  `Alloy.Agent.Server` reaches a provider only when something chats to it.
  `start_agent/2` chats to nothing, so those agents run for free and without a
  network. `start_agent_with_provider/2` does run turns, and points the agent at
  `CmsHarnessTest.HeldProvider` on localhost — a real OpenAI-compatible endpoint
  this side controls, so a turn can be caught in the middle and nothing leaves
  the machine.
  """

  import ExUnit.Assertions

  alias CmsHarnessTest.HeldProvider
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

    assert {:ok, _} =
             Machine.start_agent(agent_id, copy,
               on_stop: Keyword.get(opts, :on_stop),
               base_url: Keyword.get(opts, :base_url)
             ),
           "the premise is an agent that is actually running; without one this " <>
             "criterion asserts nothing about spending"

    ExUnit.Callbacks.on_exit(fn -> Machine.stop_agent(agent_id) end)

    agent_id
  end

  @doc """
  An agent running against a provider this criterion controls.

  Answers the id, as `start_agent/2` does. The endpoint itself is reached
  through `begin_turn/1`, `finish_turn/1` and `agent_received?/2` rather than
  handed back, so a criterion never carries a URL it has nothing to do with.

  A real agent against a real OpenAI-compatible endpoint, on localhost. Nothing
  is stubbed and no module is swapped: `Alloy.Provider.OpenAICompat` makes the
  same request it makes to z.ai, so "mid-turn" here is mid-turn the way it is
  in production.
  """
  @spec start_agent_with_provider(String.t(), keyword()) :: String.t()
  def start_agent_with_provider(agent_id, opts \\ []) do
    base_url = HeldProvider.start()

    start_agent(
      agent_id,
      opts
      |> Keyword.put(:base_url, base_url)
      |> Keyword.put(:on_event, report_to(Keyword.get(opts, :report_to)))
    )
  end

  # Where an agent's steps go. Nowhere by default — most criteria here are
  # about the process rather than the transcript, and the harness's own
  # destination is a registry a spex run has no entries in.
  defp report_to(nil), do: nil

  defp report_to(socket) do
    fn agent_id, envelope ->
      Phoenix.ChannelTest.push(socket, "agent_turn_event", %{
        "agent_id" => agent_id,
        "event" => Machine.encode_turn_event(envelope)
      })

      :ok
    end
  end

  @doc """
  Catch the agent in the middle of a turn, and leave it there.

  The premise three criteria share. Waits for the request to actually reach the
  provider before answering: without that, "the agent is busy" is a race, and a
  message sent a moment early is started rather than queued — which is the
  distinction those criteria exist to check.
  """
  @spec begin_turn(String.t()) :: :ok
  def begin_turn(agent_id) do
    HeldProvider.hold()

    assert {:ok, :started} =
             Machine.send_message(agent_id, "spex-first-turn", "work on something"),
           "the agent would not take a first message, so there is no turn for a " <>
             "second one to arrive in the middle of"

    HeldProvider.await_request()
  end

  @doc """
  Let the held turn finish, and wait until the agent has finished deciding.

  Both halves matter. Releasing alone leaves the claim racing the engine: a
  queued message goes out as the *next* turn, so "it was delivered" and "it was
  not" are both true for a moment after the first one ends.
  """
  @spec finish_turn(String.t()) :: :ok
  def finish_turn(agent_id) do
    HeldProvider.release()
    Machine.await_idle(agent_id)
  end

  @doc """
  Whether that text reached the loop that acts on it.

  Asked of the provider, not of the transcript. A conversation row proves the
  server wrote something down; this proves the agent was actually sent it,
  which is the claim — and the two came apart in exactly the way this story
  exists to fix.
  """
  @spec agent_received?(String.t(), String.t()) :: boolean()
  def agent_received?(agent_id, text) do
    Machine.await_idle(agent_id)
    Enum.any?(HeldProvider.seen(), &String.contains?(&1, text))
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
  Take back a message by the ref it was sent under, on the machine.

  Here rather than through the page for criteria whose claim is about the
  machine's answer — the page is checked by the criteria about what the
  operator is told.
  """
  @spec withdraw(String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate withdraw(agent_id, ref), to: Machine

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
