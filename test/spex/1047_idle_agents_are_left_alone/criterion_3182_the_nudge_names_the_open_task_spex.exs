defmodule CodeMySpecSpex.Story1047.Criterion3182Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3182 — The nudge names the open task.

  An agent with a task already open does not need the menu; it needs to be sent
  back to the thing it left. A generic wake here is worse than none, because
  the agent reads "there is work" against a graph whose next requirement is the
  one it is already holding, and the obvious reading is that it should start
  something.

  Two Thens, and the second is the one that fails on its own. Naming the task
  without naming the call that closes it leaves the agent to find
  `evaluate_task` — and story 538's R12 deliberately hands the *call* rather
  than the requirement for the same reason: the wake offers the door, not an
  instruction.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A wake sends the agent back to what it already holds" do
    scenario "The nudge names the open task" do
      given_ "the project chain is past kickoff, so role work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "a coding agent with that task open", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")

        context =
          start_agent_task(context, coding.id, %{
            requirement_name: "spec_file",
            entity_type: "component",
            entity_id: to_string(context.component.id)
          })

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "the agent is nudged", context do
        {:ok, put_to_work(context)}
      end

      then_ "the nudge names finishing that task", context do
        said = latest(context, context.coding)

        assert said,
               "the agent was not nudged at all, so there is no wake to inspect"

        assert said =~ ~r/(task|finish|open)/i,
               """
               The agent holds an open task and the wake says only that there
               is work.

               Read against a graph whose next requirement is the one it is
               already holding, the obvious action is to start something else —
               which is how one task becomes two.

               got: #{said}
               """

        {:ok, Map.put(context, :said, said)}
      end

      then_ "and it names the tool that closes it", context do
        assert context.said =~ "evaluate_task",
               """
               The wake names the task and not the call that finishes it, so
               the agent has to go and find it.

               Story 538's R12 hands the call rather than the requirement for
               exactly this reason: the wake offers the door, and the agent
               chooses to walk through it.

               got: #{context.said}
               """

        {:ok, context}
      end
    end
  end
end
