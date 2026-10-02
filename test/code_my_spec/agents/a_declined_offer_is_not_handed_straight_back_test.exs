defmodule CodeMySpec.Agents.ADeclinedOfferIsNotHandedStraightBackTest do
  @moduledoc """
  An agent that ends a turn without taking the work is not handed it again a
  second later.

  `Work.runnable_state?/1` tests five things — status, continuous,
  `turn_started_at`, an open reservation, an active task. A turn that ends
  *without claiming* clears every one of them, so the agent is instantly
  eligible for the offer it just refused, and ending a turn is itself enough to
  produce the observation that fires `Work.consider_project/2`. That is a
  closed loop with no damping term: offer, decline, offer, forever.

  Measured on the math project 2026-09-22, QA agent 85118c1a. Denying its
  tap-out woke it correctly — there genuinely was work — but it had concluded
  the story was blocked and every turn re-reached that conclusion:

      17:09  44 messages   79 recomputes   65 dispatches
      17:10  60           116            106
      17:11  60           112            107
      17:12  33            77             69

  197 turns in 3m29s, one every four seconds, 4,500 server log lines a minute,
  spilling onto three other working copies. Nothing stopped it; it was killed
  by hand. Every recompute behind it logged `0 entity(ies) stale`.

  `StopDecision` already defends the sibling path this way — `stuck?/3` keys on
  the rendered message and goes quiet after five repeats
  ([`AStuckLoopGoesQuietTest`]). `Work`'s own prompt went out through
  `Transport.request_work_turn/5` and had no throttle at all.

  Keyed on a fingerprint of the offer rather than a count, so genuine progress
  is never silenced: when the work changes the agent is woken immediately. The
  window in the third test is what keeps the fingerprint from becoming a wedge
  when the work never changes but its claimability does.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  # A real piece of coding work on the board. `apply_up_to_analysis/1` stops one
  # step short of `bdd_specs_passing`, so the offer under test is a named
  # requirement rather than an empty graph — without it "not admitted" is true
  # either way and the assertions cannot tell the damper from nothing to do.
  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/declined-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    Map.put(ctx, :agent, agent)
  end

  defp admitted?(scope, agent),
    do: admitted_result?(Work.request_turn_if_runnable(scope, agent, :test))

  defp admitted_result?({:ok, :offer_declined}), do: false
  defp admitted_result?({:ok, :not_runnable}), do: false
  defp admitted_result?(_dispatched), do: true

  defp reload(scope, agent) do
    {:ok, fresh} = AgentsRepository.fetch_agent(scope, agent.id)
    fresh
  end

  # What the turn-ended path does: clears the turn, then records that nothing
  # was claimed. No task is ever added, which is the whole premise.
  # A whole turn, as the real events drive it: `turn_started` clears the
  # reservation that admitting the turn stamped, `turn_ended` clears the turn
  # and records what it did. Leaving the reservation in place is what made an
  # earlier version of this test pass for the wrong reason — `runnable_state?/1`
  # refuses an agent holding one, so the refusal under test was never reached.
  defp ended_turn_without_claiming(scope, agent) do
    started = DateTime.add(DateTime.utc_now(), -30, :second)

    {:ok, agent} =
      AgentsRepository.update_agent(scope, agent, %{
        turn_started_at: nil,
        work_request_id: nil,
        work_requested_at: nil
      })

    {:ok, agent} = Work.record_decline(scope, agent, started)
    agent
  end

  defp refused_repeatedly(scope, agent, times) do
    Enum.reduce(1..times, agent, fn _, acc ->
      ended_turn_without_claiming(scope, reload(scope, acc))
    end)
  end

  # A turn that closed a task: the agent holds nothing when it ends, exactly
  # like a refusal, and is the case that must NOT be damped.
  defp ended_turn_having_finished_a_task(scope, agent) do
    started = DateTime.add(DateTime.utc_now(), -30, :second)

    task = %CodeMySpec.Sessions.Task{
      id: Ecto.UUID.generate(),
      status: :complete,
      requirement_name: "bdd_specs_passing",
      started_at: started,
      completed_at: DateTime.utc_now()
    }

    {:ok, agent} =
      AgentsRepository.update_agent(scope, agent, %{
        turn_started_at: nil,
        work_request_id: nil,
        work_requested_at: nil
      })

    {:ok, agent} = Work.record_decline(scope, %{agent | tasks: [task]}, started)
    agent
  end

  test "one refusal still permits another look", ctx do
    assert admitted?(ctx.scope, ctx.agent),
           "the premise is an agent with work waiting; it was not admitted even once"

    declined = ended_turn_without_claiming(ctx.scope, reload(ctx.scope, ctx.agent))

    assert admitted?(ctx.scope, declined),
           """
           An agent was shut out after refusing once.

           Story 1048 criterion 3570 lets a graph-admitted turn end without
           claiming and then requires the turn-end event alone to reconsider
           the unchanged work — "previously observed eligible work permits a
           later turn" — and 3572 says the same from the other side, "without
           suppressing later turns". An agent that looks again and takes it the
           second time is the system working.

           The defect is the 197th look, not the 2nd.
           """
  end

  test "the same offer refused over and over goes quiet", ctx do
    agent = reload(ctx.scope, ctx.agent)

    refused = refused_repeatedly(ctx.scope, agent, 5)

    refute admitted?(ctx.scope, refused),
           """
           The same offer was still being handed back after five refusals.

           Ending a turn without claiming clears every mark admission tests, so
           without a record of the refusals the next observation re-offers it —
           and a turn ending is itself an observation. Measured: 197 turns in
           3m29s, 60 a minute, until it was killed by hand.

           Five matches `StopDecision.stuck?/3`, which already goes quiet after
           five repeats on the sibling path.
           """
  end

  test "a turn that could not be delivered is not retried twice a second", ctx do
    # No transport registered for this copy, so the dispatch fails the way an
    # unreachable machine fails.
    Application.put_env(:code_my_spec, :agent_transport, CodeMySpec.Agents.Transport.Harness)

    agent =
      Enum.reduce(1..5, ctx.agent, fn _, acc ->
        acc = reload(ctx.scope, acc)
        {:ok, acc} = AgentsRepository.update_agent(ctx.scope, acc, %{work_request_id: nil})
        _ = Work.request_turn_if_runnable(ctx.scope, acc, :test)
        acc
      end)

    {:ok, agent} = AgentsRepository.update_agent(ctx.scope, agent, %{work_request_id: nil})

    refute admitted?(ctx.scope, reload(ctx.scope, agent)),
           """
           An undeliverable turn was offered again immediately.

           A turn that cannot be delivered never becomes a turn, so the agent
           never ends one and the turn-ended damper never runs. `release/3`
           puts it straight back into `runnable_state?/1` and the next
           observation offers the same work again — a spin on the server side
           with no agent involved at all, filling the transcript with turns
           that never happened.
           """
  end

  test "finishing a task is not declining the next one", ctx do
    # Well past the repeat cap: a productive agent must never accumulate a
    # streak at all, however many turns it takes.
    finished =
      Enum.reduce(1..8, ctx.agent, fn _, acc ->
        ended_turn_having_finished_a_task(ctx.scope, reload(ctx.scope, acc))
      end)

    assert is_nil(reload(ctx.scope, finished).declined_offer_count),
           "an agent that closed a task on every turn still accumulated refusals"

    assert admitted?(ctx.scope, reload(ctx.scope, finished)),
           """
           An agent that closed a task was damped on the next one.

           A turn that completes a task ends with the agent holding nothing,
           which is indistinguishable from a refusal by state alone — and the
           offer it would be charged with refusing is the next piece of work,
           handed over by `consider_copy(:task_completed)` moments later. Read
           that way the damper fires at exactly the point the pipeline is meant
           to advance, and every finished task costs a ten-minute wait for the
           next.
           """
  end

  # Claimed and then cancelled inside the turn: `complete_task(:cancelled)`
  # stamps `completed_at` like a real close, which is what made it read as work.
  defp ended_turn_having_cancelled_a_claim(scope, agent) do
    started = DateTime.add(DateTime.utc_now(), -30, :second)

    task = %CodeMySpec.Sessions.Task{
      id: Ecto.UUID.generate(),
      status: :cancelled,
      requirement_name: "bdd_specs_passing",
      started_at: started,
      completed_at: DateTime.utc_now()
    }

    {:ok, agent} =
      AgentsRepository.update_agent(scope, agent, %{
        turn_started_at: nil,
        work_request_id: nil,
        work_requested_at: nil
      })

    {:ok, agent} =
      Work.record_decline(scope, %{agent | tasks: [task | agent.tasks || []]}, started)

    agent
  end

  test "claiming and cancelling the offer is declining it", ctx do
    cancelled =
      Enum.reduce(1..5, ctx.agent, fn _, acc ->
        ended_turn_having_cancelled_a_claim(ctx.scope, reload(ctx.scope, acc))
      end)

    refute admitted?(ctx.scope, reload(ctx.scope, cancelled)),
           """
           An agent that claimed and cancelled the same work five times was
           offered it again.

           A cancelled task carries `completed_at`, so the turn read as having
           closed a task and every cancel cleared the damper: metric_flow QA
           claimed and cancelled `qa_journey_wallaby` and was handed it straight
           back (7169d3cf).
           """
  end

  test "work that changed since the refusal wakes it immediately", ctx do
    declined = refused_repeatedly(ctx.scope, ctx.agent, 5)

    refute admitted?(ctx.scope, declined)

    # The offer moved on: what it refused is no longer what is on the table.
    {:ok, moved_on} =
      AgentsRepository.update_agent(ctx.scope, declined, %{declined_offer: "something-else"})

    assert admitted?(ctx.scope, moved_on),
           """
           An agent was kept asleep through a change in its own work.

           The guard has to discriminate, not just suppress: a fingerprint that
           refuses a repeat must still admit a genuinely different offer, or
           this trades a spin for a stall.
           """
  end

  test "an unchanged offer is put back on the table after the window", ctx do
    declined = refused_repeatedly(ctx.scope, ctx.agent, 5)

    refute admitted?(ctx.scope, declined)

    {:ok, stale} =
      AgentsRepository.update_agent(ctx.scope, declined, %{
        declined_offer_at: DateTime.add(DateTime.utc_now(), -2 * 60 * 60, :second)
      })

    assert admitted?(ctx.scope, stale),
           """
           A two-hour-old refusal still blocked the agent.

           Claimability changes without the actionable set changing — a blocker
           cleared, a dependency finished on another copy, a tool granted — and
           none of those move the fingerprint. Without the window the agent has
           no edge left to wake it, which is the held-task wedge in a new place.
           """
  end
end
