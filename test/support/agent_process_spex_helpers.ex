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
  alias CodeMySpec.Agents.Mailbox
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
    mailbox = CodeMySpecSpex.Fixtures.mailbox_callbacks(agent_id)

    assert {:ok, _} =
             Machine.start_agent(agent_id, copy,
               on_stop: Keyword.get(opts, :on_stop),
               base_url: Keyword.get(opts, :base_url),
               on_event: Keyword.get(opts, :on_event),
               on_draft: Keyword.get(opts, :on_draft),
               on_register: mailbox[:on_register],
               on_consume: mailbox[:on_consume]
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

    {on_event, on_draft} = report_to(Keyword.get(opts, :report_to))

    start_agent(
      agent_id,
      opts
      |> Keyword.put(:base_url, base_url)
      |> Keyword.put(:on_event, on_event)
      |> Keyword.put(:on_draft, on_draft)
    )
  end

  # Where an agent's steps and drafts go. Nowhere by default — most criteria
  # here are about the process rather than the transcript, and the harness's
  # own destination is a registry a spex run has no entries in.
  #
  # Drafts go through the harness's own `DraftBuffer`, flushed on every
  # fragment rather than on `ChannelClient`'s timer, and settled by the same
  # turn events — so what reaches the channel is the payload the machine sends.
  defp report_to(nil), do: {nil, nil}

  defp report_to(socket) do
    {:ok, buffer} = Agent.start(&Machine.new_draft_buffer/0)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(buffer, :kill) end)

    on_event = fn agent_id, envelope ->
      Agent.update(buffer, &Machine.settle_draft(&1, agent_id, Map.get(envelope, :event)))

      Phoenix.ChannelTest.push(socket, "agent_turn_event", %{
        "agent_id" => agent_id,
        "event" => Machine.encode_turn_event(envelope)
      })

      :ok
    end

    on_draft = fn agent_id, %{payload: text} = envelope ->
      payloads =
        Agent.get_and_update(buffer, fn drafts ->
          drafts
          |> Machine.add_draft(agent_id, Map.get(envelope, :turn), text)
          |> Machine.take_drafts()
        end)

      Enum.each(payloads, &Phoenix.ChannelTest.push(socket, "agent_draft", &1))
      :ok
    end

    {on_event, on_draft}
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
             CodeMySpecSpex.Fixtures.send_agent_message(agent_id, "work on something"),
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
    await_mailbox_idle(agent_id, 500)
    Machine.await_idle(agent_id)
  end

  defp await_mailbox_idle(_agent_id, 0),
    do: flunk("mailbox did not settle after the provider was released")

  defp await_mailbox_idle(agent_id, attempts) do
    if Mailbox.pending?(agent_id) do
      Process.sleep(10)
      await_mailbox_idle(agent_id, attempts - 1)
    else
      :ok
    end
  end

  @doc """
  Wait until the agent has finished deciding — nothing in flight, nothing
  queued.

  What makes a claim about a turn settleable. A turn that is about to fail and
  a turn that has failed look the same from outside for as long as it is still
  running, so an assertion made a moment early is true of both.
  """
  @spec await_idle(String.t()) :: :ok
  defdelegate await_idle(agent_id), to: Machine

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
  Launch one agent by id, the way the last step of a restore does.

  The refusals it inherits are the real ones — a checkout that is gone, a
  provider nobody knows — which is what the criteria about coming back to a
  missing copy need.

  Not a whole restore. What the server would have *sent* is missing: no
  credential and no conversation, because nothing here asked the server. Use
  `restart_harness/1` for a criterion whose claim is about what survives a
  restart; this one is for claims about what refuses one.
  """
  @spec restore_agent(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def restore_agent(agent_id, working_copy) do
    Machine.ensure_supervisor()
    Machine.start_agent(agent_id, working_copy)
  end

  @doc """
  Restart the machine, and let every agent on it come back.

  Not one agent: a harness restart takes all of them, and each comes back the
  same way — the harness asks the server what it should be running, and launches
  each answer. `ChannelClient` drives exactly that loop on reconnect, so this is
  the same exchange with the socket a criterion already holds.

  Driven this way rather than by starting agents here on purpose. What a restore
  *carries* is usually the thing under test — an agent brought back with no
  credential, or with none of its conversation, looks identical from every page
  to one brought back whole — and a helper that assembled its own request would
  be asserting about the helper.
  """
  @spec restart_harness(Phoenix.Socket.t()) :: :ok
  def restart_harness(socket) do
    Enum.each(Machine.running(), &Machine.stop_agent/1)

    socket
    |> agents_to_restore()
    |> Enum.each(fn request ->
      assert {:ok, _} = CodeMySpecSpex.Fixtures.launch_agent(request),
             "the harness could not bring an agent back, so what follows is about a " <>
               "machine with no agents rather than about a restart"
    end)
  end

  @doc """
  Whether that agent is actually holding that text, as a turn it will run
  against.

  Asked of the loop rather than of the transcript. The page shows the rows
  either way — an agent that came back with its history and one that came back
  empty render the same conversation — and the difference only appears when
  somebody relies on it remembering.
  """
  @spec agent_knows?(String.t(), String.t()) :: boolean()
  def agent_knows?(agent_id, text) do
    case Machine.history(agent_id) do
      {:ok, messages} -> Enum.any?(messages, &String.contains?(Alloy.Message.text(&1), text))
      {:error, reason} -> flunk("agent #{agent_id} could not say what it knows: #{reason}")
    end
  end

  # What the server says this checkout should be running, over the harness's own
  # channel. The reply is the launch request, credential and history included.
  defp agents_to_restore(socket) do
    ref = Phoenix.ChannelTest.push(socket, "agents_to_restore", %{})

    receive do
      %Phoenix.Socket.Reply{ref: ^ref, payload: %{"agents" => agents}} -> agents
    after
      2_000 -> flunk("the server never said which agents this checkout should be running")
    end
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

  @doc """
  An agent on the held provider, reporting over `socket`, and its conversation.

  The premise the draft criteria share. The criterion joins the channel and
  opens the page itself — both are macros bound to its endpoint — and this
  starts the agent between the two. Answers the context with `:agent`,
  `:conversation` and `:conversation_path` added.
  """
  @spec agent_on_held_provider(map(), Phoenix.Socket.t(), String.t()) :: map()
  def agent_on_held_provider(context, socket, copy) do
    agent = CodeMySpecSpex.Fixtures.running_agent(context.scope, working_copy: copy)
    start_agent_with_provider(agent.id, working_copy: copy, report_to: socket)
    conversation = CodeMySpecSpex.Fixtures.agent_conversation(context.scope, agent)

    path =
      "/app/projects/#{context.project.id}/agent-conversation?" <>
        URI.encode_query(conversation: conversation.id)

    context
    |> Map.put(:agent, agent)
    |> Map.put(:conversation, conversation)
    |> Map.put(:conversation_path, path)
    |> Map.put(:harness_socket, socket)
  end

  @doc """
  Wait until the agent is idle and the server has handled everything it sent.

  `await_idle/1` is the machine's half. The turn's last events are already on
  their way to the channel by then, and `turn_ended` sets off the stop menu —
  database work that, left running, outlives the criterion and fails whichever
  one runs next with a connection its owner took away. A call to the channel
  process returns only after every message before it has been handled.
  """
  @spec await_quiet(map()) :: :ok
  def await_quiet(context) do
    await_idle(context.agent.id)
    _ = :sys.get_state(context.harness_socket.channel_pid)
    :ok
  end

  @doc """
  Ask the agent something from the page, and catch its reply part-way.

  Waits until the first half of the reply has left the provider, so "the agent
  is part-way through a reply" is a fact rather than a race.
  """
  @spec reply_part_way(map()) :: :ok
  def reply_part_way(context) do
    HeldProvider.hold_mid_reply()

    context.live
    |> Phoenix.LiveViewTest.form("form[phx-submit=send_message]", %{
      "message" => "tell me something"
    })
    |> Phoenix.LiveViewTest.render_submit()

    HeldProvider.await_request()
  end
end
