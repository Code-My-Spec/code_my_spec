defmodule CodeMySpecSpex.Story1048.Criterion3189Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3189 — One graph change, one announcement, routed per agent.

  The shape of the mechanism rather than any one of its outcomes: the graph
  says once that it moved, and the routing happens on the other side of that.

  Both halves are load-bearing and they pull against each other. One
  announcement per project is what keeps a recompute from costing a message per
  agent — a project with six agents on three copies would otherwise pay six
  broadcasts for one change. Per-agent routing is what keeps that single
  announcement from waking all six.

  The wrong design is the obvious one: announce per agent, and let the graph
  decide who hears. It satisfies every wake criterion on this story and 1047's
  as well, and it makes the recompute's cost scale with the fleet.

  `{:graph_updated, project_id}` is the announcement, and the assertion is that
  exactly one arrives — counted by draining, because "one" is a claim about
  what a listener sees and a second one arriving later is the failure.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers, only: [warm_graph: 1]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The graph announces once and the routing happens after it" do
    scenario "One graph change, one announcement, routed per agent" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a story interviewed and linked, but not yet released", context do
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

        {:ok, Map.put(context, :story, story)}
      end

      given_ "a coding agent and a QA agent on different working copies", context do
        coding_copy = join_working_copy(context, "/tmp/spex-3189-code", "the coding checkout")
        qa_copy = join_working_copy(context, "/tmp/spex-3189-qa", "the QA checkout")

        coding_scope = %{context.scope | active_working_copy_id: coding_copy.working_copy_id}

        coding =
          Fixtures.running_agent(coding_scope,
            role: "coding",
            working_copy: "/tmp/spex-3189-code"
          )

        qa_scope = %{context.scope | active_working_copy_id: qa_copy.working_copy_id}
        qa = Fixtures.running_agent(qa_scope, role: "qa", working_copy: "/tmp/spex-3189-qa")

        context =
          context |> start_session() |> put_to_work(coding_copy.working_copy_id) |> warm_graph()

        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:qa, qa.id)
         |> Map.put(:coding_before, heard_count(context, coding.id))
         |> Map.put(:qa_before, heard_count(context, qa.id))}
      end

      when_ "the graph recomputes and changes", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :announcements, drain_announcements(context))}
      end

      then_ "the graph announces the change once for the project", context do
        assert context.announcements == 1,
               """
               The graph made #{context.announcements} announcement(s) for one
               change.

               None means nothing other than the next reader learns the graph
               moved, which is the read-triggered behaviour this replaced. More
               than one means the recompute's cost scales with the fleet: a
               project with six agents on three copies pays six broadcasts for
               one change, and announcing per agent is the obvious design that
               does exactly that while satisfying every wake criterion on this
               story.
               """

        {:ok, context}
      end

      then_ "and each agent is woken or not according to its own role and working copy",
            context do
        assert heard_count(context, context.coding) > context.coding_before,
               """
               The coding agent, whose role and checkout the new work belongs
               to, was not woken by the announcement — so the routing happens
               nowhere, and one announcement is one announcement nobody acts
               on.
               """

        refute_told_anything(
          context,
          context.qa,
          context.qa_before,
          """
          The QA agent was woken by coding work on somebody else's checkout.

          One announcement for the project only works if the routing sits on
          the other side of it. Without that, "announce once" is a broadcast
          and every agent pays for every change.
          """
        )

        {:ok, context}
      end
    end
  end

  # How many times the graph said it moved. Drained rather than matched once,
  # because "once" is a claim about what a listener sees in total and a second
  # announcement arriving after the first is the failure this counts.
  defp drain_announcements(context, seen \\ 0) do
    project_id = context.scope.active_project_id

    receive do
      {:graph_updated, ^project_id} -> drain_announcements(context, seen + 1)
    after
      500 -> seen
    end
  end
end
