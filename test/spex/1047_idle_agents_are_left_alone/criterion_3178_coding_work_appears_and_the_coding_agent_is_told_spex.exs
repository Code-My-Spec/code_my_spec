defmodule CodeMySpecSpex.Story1047.Criterion3178Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3178 — Coding work appears and the coding agent is told.

  The doorbell, and the reason the rest of this story can be strict. Every
  other criterion here takes something away — no menu, no second message,
  nothing sent to the wrong role — and the cheapest way to satisfy all of them
  at once is to stop sending anything. This is the one that says the agent
  still finds out.

  An agent that stopped because its own queue was empty has nothing that would
  ever bring it back. Story 538's criterion 3108 established that finishing
  work wakes the roles it unblocked; this is the same claim from the other end,
  where the work appears rather than being unblocked.

  "The nudge names that work" is asserted separately because it fails
  separately, and a nudge that says only "there is something to do" costs the
  agent a turn finding out what.
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

  spex "An agent is told when work it can do appears" do
    scenario "Coding work appears and the coding agent is told" do
      given_ "the project chain is past kickoff, so role work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent running and idle", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = put_to_work(context)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "a story becomes ready for coding work", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")
        Fixtures.mark_story_ready(context.scope, story)

        {:ok, Map.put(context, :story, story)}
      end

      then_ "the coding agent is nudged", context do
        assert heard_count(context, context.coding) > context.before,
               """
               The coding agent heard nothing when work it can do appeared.

               An agent that stopped because its queue was empty — which is
               right — has nothing that would ever bring it back. The copy is
               staffed, switched on, and asleep.

               This is the criterion that makes the rest of this story safe to
               be strict about: every other one here takes a message away, and
               the cheapest way to satisfy all of them is to send nothing ever.
               """

        {:ok, context}
      end

      then_ "and the nudge names that work", context do
        said = latest(context, context.coding)

        assert said =~ ~r/(get_next_requirement|#{Regex.escape(context.story.title)})/,
               """
               The agent was woken and not told what for, so it spends a turn
               working out why it was woken.

               got: #{inspect(said)}
               """

        {:ok, context}
      end
    end
  end
end
