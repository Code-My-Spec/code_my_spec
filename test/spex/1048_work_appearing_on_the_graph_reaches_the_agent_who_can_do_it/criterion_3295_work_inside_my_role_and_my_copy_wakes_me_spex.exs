defmodule CodeMySpecSpex.Story1048.Criterion3295Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3295 — Work inside my role and my copy wakes me.

  Both filters satisfied at once, which is the positive case 3190 is the
  negative of. 3190 asserts that failing either filter means silence; this
  asserts that passing both means a wake — and an implementation can satisfy
  3190 by never waking anybody.

  The second Then is the one that is not implied by the first. An agent woken
  and then handed different work is being routed, and the routing is by
  something other than the graph. That is the orchestrator this project
  declined — in John's own words on story 538, "I'm dubious our orchestrator
  will make better decisions than the model" — so the wake has to lead to the
  work that caused it rather than to a decision somebody else made.

  Checked against the story that triggered the wake by name, because "some work
  was offered" is true of any menu and says nothing about routing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers, only: [warm_graph: 1]
  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is woken only by work inside its own role and checkout" do
    scenario "Work inside my role and my copy wakes me" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "a coding agent idle on its assigned working copy", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work() |> warm_graph()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "a story on that copy becomes ready for coding", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")
        :ok = Fixtures.mark_story_ready(context.scope, story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok,
         context
         |> Map.put(:story, story)
         |> Map.put(:said, said_since(context, context.coding, context.before))}
      end

      then_ "the coding agent is woken", context do
        refute context.said == [],
               """
               Work passing both filters — this agent's role, this agent's
               checkout — woke nobody.

               3190 asserts that failing either filter means silence, and an
               implementation that never wakes anybody satisfies it perfectly.
               This is the criterion that rules that out.
               """

        {:ok, context}
      end

      then_ "and the work it is given is the work that appeared", context do
        {:reply, reply, _frame} = GetNextRequirement.execute(%{}, frame(context))
        offered = response_text(reply)

        assert offered =~ Regex.escape(context.story.title),
               """
               The agent was woken by one story and offered different work.

               Being woken and then routed elsewhere is somebody deciding what
               this agent does, which is the orchestrator this project declined
               — "I'm dubious our orchestrator will make better decisions than
               the model". The graph holds the ordering; the wake is a
               doorbell, and it has to open onto the thing that rang it.

               woken by: #{context.story.title}
               offered:
               #{offered}
               """

        {:ok, context}
      end
    end
  end
end
