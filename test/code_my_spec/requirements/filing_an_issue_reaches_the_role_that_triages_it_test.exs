defmodule CodeMySpec.Requirements.FilingAnIssueReachesTheRoleThatTriagesItTest do
  @moduledoc """
  The ninety minutes of silence, as a test that can actually fail.

  Watched on 2026-09-07: a product agent stopped correctly with an empty queue
  — "No product work is currently available; I'll stop and wait to be woken
  when a product requirement is unblocked" — and sat for ninety minutes while
  four issues were filed and `issues_triaged` became actionable again.

  ## Why this is not in `the_graph_recomputes_when_its_inputs_move_test.exs`

  Because there it passed for the wrong reason, and only said so once waking
  stopped being "a pass found something" and became "a pass found something
  *new*".

  `issues_triaged` waits on `spex_boundary_ready`, which waits on
  `architecture_designed`, and so on back to `project_setup` —
  `ProjectStateFixtures` calls this "the serial chain", and `RequirementGraph`
  clamps satisfaction along it. On a bare fixture project the chain is
  unsatisfied, so `issues_triaged` is *blocked*, and filing an issue changes
  the actionable set by nothing at all. Instrumented: one entry before the
  issue, the same one entry after, and it was `personas_complete`.

  The old assertion was still green, because the old rule woke the roles
  whenever a non-first pass found anything actionable — and `personas_complete`
  was sitting there the whole time. A real wake, with the stated cause
  fabricated. Every strengthening of the wake rule would have looked like a
  regression in this test and been backed out.

  So the project is brought fully green first — `next_actionable/1` is `[]`,
  which is the agent's empty queue stated as a fact — and the premise is
  *asserted* rather than assumed at both ends: `issues_triaged` has to be quiet
  before the issue is filed and actionable after it, or the wake proves nothing.
  """

  # Not async: this swaps `:agent_transport` in the application environment,
  # which every other test shares. Run concurrently it passes alone and fails in
  # a suite, which is how it presented — the wake lands in another test's
  # recorder.
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    # The whole graph green, which is the only premise that makes this test
    # mean what its name says. `issues_triaged` waits on `spex_boundary_ready`,
    # which waits back along the serial chain to `project_setup`; kicking off
    # part of that chain just moves the frontier — measured, in order:
    # `personas_complete`, then `stories_exist`, then `architecture_designed`.
    # Filing an issue unblocks none of those, so on any partly-green project
    # the wake this asserts would have some other cause.
    #
    # Fully satisfied, `next_actionable/1` is `[]`. Then an issue is the only
    # thing that can put anything in it.
    ctx = FullSatisfactionFixtures.apply(ctx)

    :ok = GraphWatcher.settle(ctx.scope)

    ctx
  end

  defp product_agent(ctx) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        continuous: true,
        working_copy: ctx.scope.cwd,
        working_copy_id: ctx.scope.active_working_copy_id
      })

    {:ok, _} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    agent
  end

  # The claim is "a wake arrives", not "a wake arrives within half a second".
  #
  # `settle/1` answers as soon as the graph is current, and the wake goes out
  # from a Task off the watcher — deliberately, so a watcher waking inside its
  # own recompute cannot call itself. Delivery is therefore genuinely after the
  # settle returns, and how long after is a property of the machine. Draining
  # for a fixed 500ms and asserting over what had arrived failed about one run
  # in eight on a loaded box: it asserted the timer rather than the mechanism.
  #
  # So this waits for the message it is about and gives up only when it cannot
  # come — and returns the moment it does, so the wait costs nothing when the
  # machine is quick.
  @wake_timeout_ms 5_000

  defp await_wake(agent_id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wake_timeout_ms
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {:agent_dispatch, ^agent_id, _ref, message} ->
        if message =~ "Work of your kind is available",
          do: :woken,
          else: await_wake(agent_id, deadline)

      {:agent_dispatch, _other, _ref, _message} ->
        await_wake(agent_id, deadline)
    after
      max(remaining, 0) -> :never
    end
  end

  # Clearing the mailbox, which is a different question and wants no patience.
  defp drain do
    receive do
      {:agent_dispatch, _id, _ref, _message} -> drain()
    after
      50 -> :ok
    end
  end

  defp actionable_names(scope) do
    %{actionable: actionable} = Requirements.cached_graph_with_actionable(scope)
    MapSet.new(actionable, & &1.name)
  end

  test "filing an issue reaches a product agent that had stopped", ctx do
    product = product_agent(ctx)

    # The premise, and the reason this test is worth having. With no issues
    # filed `issues_triaged` is satisfied, so it is not actionable — that is the
    # agent's empty queue. If this ever stops holding, the assertion below is
    # measuring some other requirement and has to be read as a false pass.
    before = actionable_names(ctx.scope)

    refute MapSet.member?(before, "issues_triaged"),
           """
           `issues_triaged` was already actionable before any issue was filed,
           so there is nothing for filing one to unblock.

           Actionable now: #{inspect(MapSet.to_list(before))}
           """

    :ok = drain()

    {:ok, _issue} =
      Issues.create_issue(ctx.scope, %{
        title: "something is wrong",
        description: "filed while product was idle",
        severity: :medium
      })

    # `settle/1` is the debounce made deterministic: it does the pending pass
    # now instead of in two seconds. A test that slept would be asserting the
    # timer rather than the mechanism.
    :ok = GraphWatcher.settle(ctx.scope)

    after_filing = actionable_names(ctx.scope)

    assert MapSet.member?(after_filing, "issues_triaged"),
           """
           Filing an issue did not make `issues_triaged` actionable, so no wake
           is owed and the assertion below would be measuring something else.

           Either the chain in front of it is still unsatisfied — it waits on
           `spex_boundary_ready` — or `IssuesChecker.triaged?/2` does not count
           this issue as untriaged.

           Actionable: #{inspect(MapSet.to_list(after_filing))}
           """

    assert await_wake(product.id) == :woken,
           """
           An issue was filed, `issues_triaged` became actionable, and the role
           that triages it heard nothing. This is the ninety minutes of silence:
           the agent said it would wait to be woken when a product requirement
           was unblocked, and filing an issue is exactly that happening.
           """
  end
end
