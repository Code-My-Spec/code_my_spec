defmodule CodeMySpec.Agents.AStrandedTurnRequestStopsBlockingATurnTest do
  @moduledoc """
  A turn handed to a harness that nobody is coming back for lapses instead of
  wedging the agent forever.

  `Work.runnable_state?/3` refuses an agent with a turn on its way — an open
  offer stamped `turn_requested_at` (`Offers.in_flight?/1`) — which is right
  while the dispatch is in flight: it is what makes admission idempotent when
  two events race. The window is meant to be the seconds between handing the
  turn over and the agent reporting it started.

  Every path that closes the request needs a live process, though: the failed
  dispatch, and the agent's own turn ending. So the one case that strands it —
  the process going away *after* the transport accepted it — is exactly the
  case nothing cleans up.

  Measured on the math project, 2026-09-22, when this was a reservation on the
  agent row: the coding agent stamped one at 01:53, the harness restarted three
  times, and the row carried it through every one. Four roles sat idle for two
  hours over a `spex_boundary_ready` that was ready the whole time.

  Sibling of [`AReapedAgentCanBeAdmittedAgainTest`] — there the agent comes back
  from a reap, here it never appears to have left.
  """
  use CodeMySpecSpex.Case, async: true

  import Ecto.Query

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offer
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The premise is an agent with real work waiting. `apply_up_to_analysis/1`
  # stops one step short of `bdd_specs_passing`, which leaves a named piece of
  # coding work on the board — without it "not admitted" is true either way and
  # the assertion cannot tell a stale turn request from an empty graph.
  setup ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/stranded-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    Map.put(ctx, :agent, agent)
  end

  defp holding(agent, seconds_ago) do
    {:ok, held} = Offers.dispatch(agent, :resume, {"task", "earlier"})
    at = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    Repo.update_all(from(o in Offer, where: o.id == ^held.id), set: [turn_requested_at: at])
    held
  end

  # Admission is observed through the turn requests rather than the return
  # value, because `request_turn_if_runnable/4` answers `{:ok, :not_runnable}`
  # both for an agent the guard refused and for one with nothing to do — the two
  # cases this has to tell apart. Passing the guard is what writes a new one.
  defp handed_another?(agent_id, held) do
    from(o in Offer,
      where: o.agent_id == ^agent_id and o.id != ^held.id and not is_nil(o.turn_requested_at)
    )
    |> Repo.exists?()
  end

  test "a turn request older than the dispatch window stops blocking admission", ctx do
    held = holding(ctx.agent, 2 * 60 * 60)

    _ = Work.request_turn_if_runnable(ctx.scope, ctx.agent, :test)

    assert handed_another?(ctx.agent.id, held),
           """
           A two-hour-old turn request still refused the agent a turn.

           Nothing is coming back to close it: the process that would have is
           gone, and a harness restart re-reports the agent as running rather
           than reaping it, so the request rides into the next life and the
           agent is un-admittable for good.
           """
  end

  test "a turn request still inside the dispatch window is left alone", ctx do
    held = holding(ctx.agent, 5)

    _ = Work.request_turn_if_runnable(ctx.scope, ctx.agent, :test)

    refute handed_another?(ctx.agent.id, held),
           """
           A five-second-old turn request was ignored and a second turn handed out.

           That window is a real dispatch in flight, and the request is what
           makes two events racing to admit the same agent idempotent.
           """
  end
end
