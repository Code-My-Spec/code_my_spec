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

  alias CmsHarness.Project.ChannelClient
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
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

    AgentPresence.present(agent)

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

  test "an undeliverable turn is recorded as offer attempts, not a refusal", ctx do
    # No transport registered for this copy, so the dispatch fails the way an
    # unreachable machine fails.
    Application.put_env(:code_my_spec, :agent_transport, CodeMySpec.Agents.Transport.Harness)

    agent =
      Enum.reduce(1..3, ctx.agent, fn _, acc ->
        acc = reload(ctx.scope, acc)
        {:ok, acc} = AgentsRepository.update_agent(ctx.scope, acc, %{work_request_id: nil})
        _ = Work.request_turn_if_runnable(ctx.scope, acc, :test)
        acc
      end)

    # Each failed dispatch is its own offer, settled undelivered — never ignored —
    # and nothing reads as the agent having said no.
    offers = Offers.list_for_agent(agent.id)
    assert length(offers) == 3
    assert Enum.all?(offers, &(to_string(&1.status) == "undelivered"))
    assert is_nil(reload(ctx.scope, agent).declined_offer)
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
  # A whole turn through the real events, so the turn end settles the offer
  # admission recorded (story 1080's ladder) rather than a hand-set mark.
  defp turn_ended(scope, agent, extra_tasks \\ []) do
    agent =
      Enum.reduce(extra_tasks, Repo.get!(CodeMySpec.Agents.Agent, agent.id), fn attrs, acc ->
        {:ok, acc} = acc |> CodeMySpec.Agents.Agent.add_task(attrs) |> Repo.update()
        acc
      end)

    {:ok, agent} =
      AgentsRepository.update_agent(scope, agent, %{
        turn_started_at: DateTime.add(DateTime.utc_now(), -30, :second),
        work_request_id: nil,
        work_requested_at: nil
      })

    :ok =
      CodeMySpec.Agents.record_turn_event(
        scope,
        agent.id,
        ChannelClient.encode_turn_event(CodeMySpecSpex.Fixtures.mailbox_turn_end(scope, agent.id))
      )
  end

  # Issue 56a2d806: `id` here is the story's public number, named in
  # `subject_key` the same way `get_next_requirement` names it, not the
  # database id a real cancelled task's own `story_id` carries -- resolved
  # back the same way `Offers.tasks_on/2` now resolves it to match.
  defp on_entity(scope, "story", id),
    do: %{story_id: CodeMySpec.Stories.get_story_by_number!(scope, id).id}

  defp on_entity(_scope, "component", id), do: %{component_id: id}
  defp on_entity(_scope, "project", id), do: %{project_id: id}

  defp latest_offer(agent), do: agent.id |> Offers.list_for_agent() |> List.last()

  # A turn end re-offers by itself, off this process. The recording transport's
  # turn request is the sync point: each ended turn settles one offer, and the
  # next offer is the turn the transport records.
  test "the same work ignored three times is held back from this agent (1741)", ctx do
    id = ctx.agent.id
    assert admitted?(ctx.scope, reload(ctx.scope, ctx.agent))
    held = latest_offer(ctx.agent).subject_key

    for _ <- 1..3 do
      assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
      turn_ended(ctx.scope, ctx.agent)
    end

    assert %{ignored: 3, held?: true} = Offers.standing(id)[held]

    refute_receive {:work_turn_requested, ^id, _ref, _prompt},
                   1_000,
                   """
                   Work this agent ignored three times was offered to it a fourth time.

                   Ending a turn without claiming clears every mark admission tests, so
                   without the ladder the next observation re-offers it — and a turn
                   ending is itself an observation. Measured: 197 turns in 3m29s, 60 a
                   minute, until it was killed by hand.
                   """
  end

  test "claiming and cancelling the offered work is declining it", ctx do
    assert admitted?(ctx.scope, reload(ctx.scope, ctx.agent))
    %{subject_key: key} = latest_offer(ctx.agent)
    [type, id, name] = String.split(key, ":", parts: 3)

    cancelled =
      Map.merge(on_entity(ctx.scope, type, id), %{
        status: :cancelled,
        requirement_name: name,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })

    turn_ended(ctx.scope, ctx.agent, [cancelled])

    assert %{status: :declined, reason: "claimed and cancelled"} = latest_offer(ctx.agent)

    assert %{held?: true} = Offers.standing(ctx.agent.id)[key],
           """
           An agent that claimed and cancelled the offered work was free to be
           offered it again: metric_flow QA claimed and cancelled
           `qa_journey_wallaby` and was handed it straight back (7169d3cf).
           """
  end
end
