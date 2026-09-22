defmodule CodeMySpec.Agents.AStrandedReservationStopsBlockingATurnTest do
  @moduledoc """
  A turn reservation nobody is coming back for expires instead of wedging the
  agent forever.

  `Work.runnable_state?/1` refuses an agent holding a `work_request_id`, which
  is right while a dispatch is in flight — the stamp is what makes admission
  idempotent when two events race. The window is meant to be the seconds
  between stamping a turn and the agent reporting it started; the turn itself
  is guarded separately by `turn_started_at`.

  Every path that clears the stamp needs a live process, though: `release/3`
  when the dispatch errors, and the agent's own completion. So the one case
  that strands a reservation — the process going away *after* the transport
  accepted it — is exactly the case nothing cleans up. `record_stopped/2`
  clears it when a reap notices the agent is gone, but a harness restart
  re-reports the agent as running, and `record_running_on_copy/3` leaves an
  already-`:running` row alone. That row is the one holding the stale stamp.

  Measured on the math project, 2026-09-22: the coding agent stamped a
  reservation at 01:53, the harness restarted three times, and the row carried
  it through every one. Four roles sat idle for two hours over a
  `spex_boundary_ready` that was ready the whole time, because the three others
  were waiting on coding's requirement and coding was un-admittable.

  Sibling of [`AReapedAgentCanBeAdmittedAgainTest`] — there the agent comes back
  from a reap, here it never appears to have left.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The premise is an agent with real work waiting. `apply_up_to_analysis/1`
  # stops one step short of `bdd_specs_passing`, which leaves a named piece of
  # coding work on the board — without it "not admitted" is true either way and
  # the assertion cannot tell a stale reservation from an empty graph.
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

    Map.put(ctx, :agent, agent)
  end

  defp holding(scope, agent, seconds_ago) do
    {:ok, held} =
      AgentsRepository.update_agent(scope, agent, %{
        work_request_id: Ecto.UUID.generate(),
        work_requested_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
      })

    held
  end

  # Admission is observed through the row rather than the return value, because
  # `request_turn_if_runnable/3` answers `{:ok, :not_runnable}` both for an
  # agent the guard refused and for one with nothing to do — the two cases this
  # has to tell apart. Reaching `reserve/1` stamps a *fresh* ref over the stale
  # one, and the dispatch that follows fails for an agent with no process behind
  # it and releases it. Either way the stale ref is gone, and only passing the
  # guard can remove it.
  defp stale_ref_cleared?(agent_id, ref) do
    Repo.get(Agent, agent_id).work_request_id != ref
  end

  test "a reservation older than the dispatch window stops blocking admission", ctx do
    held = holding(ctx.scope, ctx.agent, 2 * 60 * 60)

    _ = Work.request_turn_if_runnable(ctx.scope, held, :test)

    assert stale_ref_cleared?(held.id, held.work_request_id),
           """
           A two-hour-old reservation still refused the agent a turn.

           Nothing is coming back to release it: the process that would have is
           gone, and a harness restart re-reports the agent as running rather
           than reaping it, so the stamp rides into the next life and the agent
           is un-admittable for good.
           """
  end

  test "a reservation still inside the dispatch window is left alone", ctx do
    held = holding(ctx.scope, ctx.agent, 5)

    _ = Work.request_turn_if_runnable(ctx.scope, held, :test)

    refute stale_ref_cleared?(held.id, held.work_request_id),
           """
           A five-second-old reservation was overwritten.

           That window is a real dispatch in flight, and the stamp is what makes
           two events racing to admit the same agent idempotent. Expiring it
           here would hand the same turn out twice.
           """
  end
end
