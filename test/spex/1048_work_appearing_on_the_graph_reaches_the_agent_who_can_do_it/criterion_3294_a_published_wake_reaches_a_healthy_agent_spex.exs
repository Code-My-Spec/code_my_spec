defmodule CodeMySpecSpex.Story1048.Criterion3294Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3294 — A published wake reaches a healthy agent.

  The other half of 3194, and the reason 3194 is safe. There the agent is
  unreachable and nothing retries, waits, or acknowledges; here the agent is
  fine and the message still has to arrive.

  Written as its own criterion because "fire and forget" has a degenerate
  reading that passes 3194 perfectly: forget to fire. No retries, no waiting,
  no acknowledgement, and no delivery either — and every silence criterion on
  this story and on 1047 is satisfied by it.

  The second Then is the design being asserted rather than the outcome.
  Delivery happens because the publish reaches a subscriber, not because
  anything confirmed it did — so there must be no acknowledgement in the path
  at all. An implementation that delivers *and* waits for a confirmation passes
  the first Then and reintroduces exactly the coupling 3194 forbids.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers, only: [warm_graph: 1]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens

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

  spex "The graph's job ends when it has said what changed" do
    scenario "A published wake reaches a healthy agent" do
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

      given_ "a coding agent running and idle", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work() |> warm_graph()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "work appears and the wake message is published", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :said, said_since(context, context.coding, context.before))}
      end

      then_ "the agent receives it and begins a turn", context do
        refute context.said == [],
               """
               A healthy agent was not delivered a wake for work it can do.

               "Fire and forget" has a degenerate reading that satisfies 3194
               perfectly: forget to fire. No retries, no waiting, no
               acknowledgement — and no delivery. Every silence criterion on
               this story and on 1047 passes against it.
               """

        {:ok, context}
      end

      then_ "and nothing had to confirm delivery for that to happen", context do
        refute Enum.any?(
                 context.said,
                 &(&1 =~ ~r/(acknowledge|confirm receipt|delivery receipt)/i)
               ),
               """
               The wake path carries an acknowledgement.

               An implementation that delivers and then waits for confirmation
               passes the Then above and reintroduces exactly the coupling 3194
               forbids: one agent's closed laptop holding up the recompute the
               whole project reads from.

               #{Enum.join(context.said, "\n---\n")}
               """

        {:ok, context}
      end
    end
  end
end
