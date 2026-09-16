defmodule CodeMySpecSpex.Story1048.Criterion3198Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3198 — A recompute that fails wakes nobody.

  The honest statement of what this mechanism cannot do, written down so it is
  a known limit rather than a surprise.

  Everything on this story hangs off the graph announcing that it moved. If the
  recompute fails there is no announcement, and no amount of correctness in the
  routing recovers that — the routing never runs. So the criterion asserts the
  silence, and then names the thing that does catch it.

  That last clause is what makes this worth writing rather than a caveat in a
  moduledoc. "No agent is woken" on its own describes a project that quietly
  stops: work outstanding, agents idle, every page showing a healthy fleet. The
  cadence check is the second mechanism that exists precisely because the first
  one can be silent — the main agent looks in on its agents on a schedule and
  compares what is waiting against what is running, which is a question that
  does not depend on any announcement having been made.

  Two mechanisms, one of them not event-driven, is the design. This criterion
  is where that is stated.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers, only: [warm_graph: 1]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.McpServers.MainAgent.Tools.CheckIn
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A silent graph is caught by the cadence, not by the graph" do
    scenario "A recompute that fails wakes nobody" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent running and idle on its working copy", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        main = Fixtures.running_agent(context.scope, role: "main")
        context = context |> start_session() |> put_to_work() |> warm_graph()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:main, main.id)}
      end

      given_ "work waiting on that working copy", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refunds reach the ledger",
            description: "Interviewed and waiting to be released",
            acceptance_criteria: ["A refund lands on the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        :ok = Fixtures.mark_story_ready(context.scope, story)

        # Settled and captured here, not in the previous `given_`. Marking
        # the story ready is real work appearing, and it legitimately wakes
        # the coding agent -- correctly, before the `when_` ever injects a
        # fault. A `:before` taken ahead of this block would count that
        # legitimate wake as if the failed recompute below had caused it.
        :ok = Fixtures.settle_graph(context.scope)

        {:ok,
         context
         |> Map.put(:story, story)
         |> Map.put(:before, heard_count(context, context.coding))}
      end

      when_ "the graph fails to recompute and makes no announcement", context do
        :ok = Fixtures.break_graph_recompute(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        # Expected: `GraphWatcher.recompute/1` logs this failure at `:error`
        # by design (see its own moduledoc), and `SexySpex.ErrorCapture`
        # fails any spex running when an `:error` lands — including this
        # one's own deliberately injected fault. Cleared rather than left,
        # since it is this scenario's premise and not a straggler.
        SexySpex.ErrorCapture.clear()

        {:ok, context}
      end

      then_ "no agent is woken", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          Something woke the agent even though the recompute failed.

          A wake sent without a recompute behind it is a wake nothing checked:
          it names work that may not be there, on a checkout it may not be on.
          """
        )

        {:ok, context}
      end

      then_ "and the agent stays idle with work outstanding", context do
        assert Fixtures.role_queue_size(context.scope, context.coding) > 0,
               "the premise is an agent with work waiting that it has not been told about"

        {:ok, context}
      end

      then_ "and the main agent's cadence check is what surfaces it", context do
        {:reply, _reply, _frame} = CheckIn.execute(%{}, frame(context))
        report = context |> heard(context.main) |> List.last()

        assert report =~ ~r/(no task claimed|does hold work|nothing to do)/i,
               """
               The cadence check does not surface a project that has quietly
               stopped.

               Without it, a failed recompute leaves work outstanding, agents
               idle, and every page showing a healthy fleet — and nothing that
               will ever notice, because everything else on this story hangs
               off an announcement that was never made.

               The cadence is the second mechanism, and the reason it is not
               event-driven is exactly this case.

               #{inspect(report)}
               """

        {:ok, context}
      end
    end
  end
end
