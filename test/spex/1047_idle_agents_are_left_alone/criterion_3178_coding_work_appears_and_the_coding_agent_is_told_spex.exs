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

  spex "An agent is told when work it can do appears" do
    scenario "Coding work appears and the coding agent is told" do
      given_ "a project with nothing left for anybody to do", context do
        {:ok, CodeMySpecSpex.FullSatisfactionFixtures.apply(context)}
      end

      given_ "a second story interviewed and linked, but not yet released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refunds reach the ledger",
            description: "Interviewed and waiting to be released",
            acceptance_criteria: ["A refund lands on the ledger"],
            # `create_story` releases by default, and a released story with its
            # interview sealed is already in the coding lane — so the agent was
            # nudged during the given and the when_ had nothing left to cause.
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
        context = put_to_work(context)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "the story is released, putting its specs in the coding lane", context do
        # Releasing is what makes a story visible to the graph at all —
        # `Preloader` filters to `ready_for_dev == true` — and with its
        # interview already sealed the first thing it projects is
        # `bdd_specs_exist`, which belongs to coding.
        #
        # The criterion released a bare story before, which projects
        # `component_linked` and `three_amigos_complete`, both product's. The
        # coding lane never moved, so "the coding agent heard nothing" was the
        # correct answer to a scenario that had put nothing there.
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
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
