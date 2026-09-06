defmodule CodeMySpecSpex.Story538.Criterion3106Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 3106 — A coding agent is not held open by product's queue.

  Rule R10: work is counted for the agent's own role. Whether there is anything
  to do is asked of the requirements this agent's role can satisfy, not of the
  project's whole graph.

  ## Why this is the criterion that makes the loop safe to switch on

  Without it, three agents staffed on one copy each ask "does this project have
  work", all three get the same yes, and none can ever finish: a QA agent loops
  on implementation it will not write, a coding agent is held open by a spec
  nobody has agreed yet. Story 895 stopped them taking *another copy's* stories;
  this stops them taking each other's.

  R6 is the other half and falls out of the same answer — an agent whose own
  queue is empty stops while the project stays busy.

  ## Why the counts are measured twice

  A first draft compared coding's count against product's at one moment and
  asserted they differed. They did not: both read 2 on this fixture, by
  coincidence of where the graph sits, and the criterion failed while the code
  was right. Two agents can legitimately have the same amount of work.

  What cannot happen under R10 is coding's count *moving because product's did*.
  So work only product can act on is added between the two measurements — a
  story with no component linked, whose `component_linked` is product's and
  whose coding requirements are all still blocked behind it. Product's number
  rises; coding's must not.

  ## Where the role comes from

  `RequirementDefinition.role`, which was `subagent_role` until 2026-09-05 and
  set on one definition out of seventy. John: *"Change subagent role to just
  role and reuse — that's what that field was for."*

  Surface: the real one — a turn ends, `StopDecision` decides, and what each
  agent is told lands in its own conversation.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.SetWorkingCopyLoop
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

  spex "Work is counted for the agent's own role" do
    scenario "A coding agent is not held open by product's queue" do
      given_ "the project chain is past kickoff, so story work is the frontier",
             context do
        # Story requirements sit behind `qa_setup` — the whole-project gate that
        # opens story-level work. Without this every role's count is the
        # project-level handful, adding a story changes nothing, and the
        # comparison below is 2 against 2 twice over.
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "a coding agent and a product agent, both working", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        product = Fixtures.running_agent(context.scope, role: "product")

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: context.scope.active_working_copy_id, working: true},
            frame
          )

        {:ok, context |> Map.put(:coding, coding.id) |> Map.put(:product, product.id)}
      end

      given_ "each has finished a turn, so what they were told is on record", context do
        {:ok, Map.put(context, :before, counts(context))}
      end

      when_ "work only product can act on arrives", context do
        # A story with no component linked. `component_linked` is product's, and
        # the story's coding requirements sit behind it — so this adds to
        # product's queue and to nobody else's.
        StoryHelpers.create_story(context.scope,
          title: "Something product has to shape first",
          description: "As a user, I want a thing, so that I get the thing.",
          acceptance_criteria: ["It does the thing"]
        )

        {:ok, Map.put(context, :after, counts(context))}
      end

      then_ "product is given more to do", context do
        assert context.after.product > context.before.product,
               "product's queue did not grow when work only product can do " <>
                 "arrived, so this scenario cannot tell whether coding is " <>
                 "insulated from it. before=#{inspect(context.before)} " <>
                 "after=#{inspect(context.after)}"

        {:ok, context}
      end

      then_ "and coding is not", context do
        assert context.after.coding == context.before.coding,
               "coding's count moved because product's did. That is a coding " <>
                 "agent held open by a queue it cannot act on: it loops until " <>
                 "somebody else finishes, doing nothing, and R6 can never let it " <>
                 "go home. before=#{inspect(context.before)} " <>
                 "after=#{inspect(context.after)}"

        {:ok, context}
      end
    end
  end

  # End both turns and read back what each was told, as counts.
  #
  # `get_next_requirement` first, because the loop counts from the requirements
  # read model and that call is what populates it. A graph nobody has computed
  # counts zero for every role, and every comparison here would be zero against
  # zero.
  defp counts(context) do
    frame = %Frame{assigns: %{current_scope: context.scope}}
    {:reply, _next, _frame} = GetNextRequirement.execute(%{}, frame)

    :ok = Fixtures.end_turn(context.scope, context.coding)
    :ok = Fixtures.end_turn(context.scope, context.product)

    %{
      coding: offered(context.scope, context.coding),
      product: offered(context.scope, context.product)
    }
  end

  # How many requirements the most recent menu offered this agent, off the
  # `Next:` line. Most recent rather than all: the agent is told once per turn
  # and this scenario ends two.
  defp offered(scope, agent_id) do
    scope
    |> Fixtures.orchestrator_actions(agent_id)
    |> Enum.map(&inspect/1)
    |> Enum.reverse()
    |> Enum.find_value(0, fn said ->
      case Regex.run(~r/Next: (\d+) requirement/, said) do
        [_, n] -> String.to_integer(n)
        nil -> nil
      end
    end)
  end
end
