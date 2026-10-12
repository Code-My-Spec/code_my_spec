defmodule CodeMySpec.Agents.AnIdleQaWithAStaleResumeIsStillOfferedQaWorkTest do
  @moduledoc """
  A continuous, idle QA is offered `qa_complete` when `ready_for_qa` passes.

  Reported 2026-10-06: a continuous, idle QA agent (team 2, `ec69605d`) was not
  offered story 1092's `qa_complete` for 12+ minutes after `ready_for_qa` passed
  at 03:07 — no offer row at all, and its newest offer was an open `:resume`
  from the 01:20 restart. Team 3's QA did the same with 1016 at 02:15.

  ## What was actually wrong

  Two candidates were in the report, and this test separates them. It is
  neither of the obvious ones:

    1. *An open `:resume` blocks new offers.* It does not, and it did not.
       `Work.admission/3` and `Wake.decide/3` both answer `:wake`/`:ok` for a
       `:work_offer` with a resume offer open — asserted below, because that is
       the check that rules the report's own suspect out.

    2. *QA's copy is not where the graph offers the work.* This is the real
       one, and it is about `Work.claimable_work/2` re-scoping to the agent's
       **own** checkout (`at_copy/2`) and reading the **team's** story there
       (`Assignment`/`work_for`): `actionable(scope, :qa)` — answered at the
       scope's copy — returns `["qa_complete"]`, while
       `claimable_work(scope, qa)` — answered at QA's own copy — returns `[]`.

  So the graph has the work and the agent is offered nothing, which is exactly
  the report's shape. The reason a real QA does *not* normally hit this is
  `Assignment.assign_team/3`: a story is assigned to the whole team on a copy —
  coding **and** QA — and `Assignment.inherit/2` gives a QA joining a copy its
  teammates' story. QA is therefore only offered anything while its copy's team
  holds a story, which is the production shape this test builds.

  Criterion 3199 deliberately puts both agents on **one** copy ("split across
  copies, a checkout filter alone would pass this and the role filter would
  never be exercised"), so the split-copy reading was never covered. This test
  covers it: QA on its own copy, with the team's story assigned to that copy
  the way `assign_team/3` assigns it.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Repo

  alias CodeMySpec.WorkingCopies
  import CodeMySpec.DevicesFixtures
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport()
    :ok
  end

  setup ctx do
    {:ok, _} = WorkingCopies.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    # The team's feature copy -- the copy the story's work is done on, so the
    # graph there reads the chain as satisfied. Production shape (operator,
    # 2026-10-07): a team's QA shares the coder's copy. Team 2's QA `ec69605d`
    # and coder `3f358d8e` were both on copy 53753334, bound to 1092.
    {:ok, copy} =
      WorkingCopies.issue(ctx.scope, nil,
        label: "team's feature checkout",
        device: device_fixture(ctx.scope)
      )

    scope =
      Fixtures.put_fixture_environment(
        %{ctx.scope | active_working_copy_id: copy.id},
        ctx.environment
      )

    ctx = %{ctx | scope: scope}

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    ctx = HarnessHooks.ensure_live_harness(ctx)

    # Coding holds `ready_for_qa` alone; the transition below is the one thing
    # that turns QA's work on.
    Fixtures.fresh_analysis_runs(ctx.scope, ["compiler", "credo", "exunit"])

    coding = team_agent(ctx.scope, "coding", copy.id)
    qa = team_agent(ctx.scope, "qa", copy.id)

    {:ok, _} = Assignment.assign_team(ctx.scope, copy.id, ctx.story.id)

    :ok = Fixtures.watch_graph(ctx.scope)

    Map.merge(ctx, %{qa_copy: copy, qa: qa, coding: coding})
  end

  defp team_agent(scope, role, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: true,
        status: :running,
        working_copy: "/tmp/#{role}-#{System.unique_integer([:positive])}",
        working_copy_id: copy_id
      })

    CodeMySpecTest.AgentPresence.present(agent)
    agent
  end

  # The stale resume `account_for_interrupted_turn/2` leaves behind: recorded
  # and never superseded, because the harness came back without dispatching it.
  defp stale_resume(agent) do
    %Offer{} = Offers.record(nil, agent, :resume, {"restart", nil})
    :ok
  end

  # The premise the offer below rests on, read through the same path the offer
  # takes: a bound agent at its own copy, with the team's story, sees the QA
  # node once the story's chain is satisfied. `claimable_work/2` re-scopes to
  # the agent's copy and binds it to its story, so this is what a live offer
  # would see -- not `actionable_names/2`, which reads the graph with no owner
  # and answers `[]` for a story whose work is placed elsewhere.
  test "the team's story reaches QA's own copy, so the graph offers it work", ctx do
    ctx = FullSatisfactionFixtures.apply_qa_readiness_transition(ctx)
    :ok = Fixtures.settle_graph(ctx.scope)

    assert Work.claimable_work(ctx.scope, Repo.get!(Agent, ctx.qa.id))
           |> Enum.map(& &1.name) == ["qa_complete"],
           """
           QA's own copy no longer reads the team's story, so the offer below
           would be measuring an empty graph rather than a delivered offer.
           """
  end

  test "an idle continuous QA is offered qa_complete when ready_for_qa passes", ctx do
    :ok = stale_resume(ctx.qa)

    ctx = FullSatisfactionFixtures.apply_qa_readiness_transition(ctx)
    :ok = Fixtures.settle_graph(ctx.scope)

    qa = Repo.get!(Agent, ctx.qa.id)

    # The premise the report rests on: there was work to offer. Read through
    # `claimable_work/2`, which is the path the offer itself takes -- it reads
    # the graph at the *agent's* copy, with the agent bound to its story, and
    # withholds what a teammate holds. `actionable_names/2` reads the graph with
    # no owner at all, so it answers `[]` here while the offer path answers
    # `["qa_complete"]`, and asserting on it measured the fixture rather than
    # the offer.
    assert ["qa_complete"] = Work.claimable_work(ctx.scope, qa) |> Enum.map(& &1.name)

    assert {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, qa, :work)

    offers = Offers.list(ctx.scope, agent_id: ctx.qa.id)

    assert Enum.any?(offers, &(&1.kind == :work)),
           """
           QA was offered no work after `ready_for_qa` passed.

           QA-actionable: #{inspect(Fixtures.actionable_names(ctx.scope, :qa))}
           Offers on this agent: #{inspect(Enum.map(offers, &{&1.kind, &1.subject_type, &1.subject_key, &1.status}))}
           """
  end

  test "an open resume offer does not hold the agent out of a work offer", ctx do
    :ok = stale_resume(ctx.qa)

    ctx = FullSatisfactionFixtures.apply_qa_readiness_transition(ctx)
    qa = Repo.get!(Agent, ctx.qa.id)

    assert Work.admission(ctx.scope, qa, :work_offer) == :ok,
           """
           An open `:resume` offer held this agent out of `:work_offer`.

           admission: #{inspect(Work.admission(ctx.scope, qa, :work_offer))}
           """
  end

  # The recovery path must still work: a resume of a stranded task (story 1080,
  # criterion 3321) is admitted whether or not one is already open.
  test "a resume is still admitted while its offer is open", ctx do
    :ok = stale_resume(ctx.qa)

    assert Work.admission(ctx.scope, Repo.get!(Agent, ctx.qa.id), :resume) == :ok
  end
end
