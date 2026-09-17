defmodule CodeMySpec.Agents.OneEventIsOneWakeTest do
  @moduledoc """
  One graph change is one nudge, however many observations it drained as.

  Issue `6f1bd3af`, criterion 3180 ("One turn ends, one nudge arrives"). Agent
  `0067d652` was handed three byte-identical "Work of your kind is available"
  messages 128ms apart on 2026-09-17 — same six open tasks, same `task_id`, no
  turn boundary between them — and then spent four turns re-confirming that
  nothing had changed.

  ## Why `@stuck_threshold` was never going to catch it

  `stuck?/3` counts identical sends and suppresses past five. That bounds the
  *tail* — an agent nagged about an unresolved menu across many separate stop
  hooks — and says nothing about three sends inside 128ms, which is nowhere
  near six.

  ## Why the fix is here and not in `GraphWatcher`

  `GraphWatcher.maybe_wake/2` gates on "a real observation landed" rather than
  on the actionable set changing, and that is deliberate: problems are coding
  work the graph never carries as a requirement, so a wake gated on the
  actionable diff never fires for one (3193). Its recorded cost was "a rendered
  menu on a pass that changed requirements not at all; the message count for
  that case is unchanged, because `Menu.render/4` was always going to answer
  `\"\"`" — true of an *empty* menu, and false of an agent that already has
  work, which renders the same non-empty text on every drain.

  So the trigger stays wide and the sender dedupes. Only a byte-identical
  message is suppressed; a menu that changed is a different key and never
  reaches the debounce at all.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        continuous: true,
        working_copy: "/tmp/one-wake-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    on_exit(fn -> :persistent_term.erase({StopDecision, :wake, agent.id}) end)

    %{scope: scope, agent: agent}
  end

  defp holding(agent, task_id) do
    task = %CodeMySpec.Sessions.Task{
      id: task_id,
      status: :active,
      requirement_name: "qa_complete",
      started_at: DateTime.utc_now()
    }

    %{agent | tasks: [task]}
  end

  defp drain(acc \\ []) do
    receive do
      {:agent_dispatch, _id, _ref, message} -> drain([message | acc])
      {:agent_message, _id, message} -> drain([message | acc])
    after
      200 -> acc
    end
  end

  defp wakes(messages),
    do: Enum.count(messages, &String.contains?(&1, "Work of your kind is available"))

  # Elapsed time without a sleep: the slot is the only thing the debounce reads,
  # so ageing its timestamp is exactly equivalent to waiting, and deterministic.
  defp age_the_slot(agent_id, by_ms) do
    slot = {StopDecision, :wake, agent_id}
    {key, count, sent_at} = :persistent_term.get(slot)
    :persistent_term.put(slot, {key, count, sent_at - by_ms})
  end

  test "one event draining as three observations wakes the agent once", ctx do
    busy = holding(ctx.agent, Ecto.UUID.generate())

    for _ <- 1..3, do: StopDecision.wake(ctx.scope, busy)

    assert wakes(drain()) == 1, """
    Three wakes for one graph change put more than one message in front of the
    agent.

    This is `6f1bd3af` exactly: the menu is deterministic on current state, so
    every call in a drain burst renders the identical text, and each one the
    agent picks up costs it a turn. Three turns bought with one piece of
    information, against criterion 3180 — "one turn ends, one nudge arrives".
    """
  end

  test "a menu that actually changed is never suppressed", ctx do
    for _ <- 1..3 do
      StopDecision.wake(ctx.scope, holding(ctx.agent, Ecto.UUID.generate()))
    end

    assert wakes(drain()) == 3, """
    A wake naming different work each time was silenced as though it were a
    repeat.

    The debounce keys on the rendered message, and that is the whole reason it
    is safe: real movement changes the text and must always get through.
    Suppressing it would trade a burst of noise for an agent that never hears
    about work.
    """
  end

  test "the same menu is sent again once the burst window has passed", ctx do
    busy = holding(ctx.agent, Ecto.UUID.generate())

    StopDecision.wake(ctx.scope, busy)
    assert wakes(drain()) == 1

    age_the_slot(ctx.agent.id, :timer.seconds(60))
    StopDecision.wake(ctx.scope, busy)

    assert wakes(drain()) == 1, """
    An identical menu was still suppressed long after the burst it belonged to.

    This has to be a debounce and not a mute. A wake can be lost with a
    restarting agent's queue, and the backstop for that is the next one landing
    — `@stuck_threshold` is what stops it repeating forever, not this.
    """
  end
end
