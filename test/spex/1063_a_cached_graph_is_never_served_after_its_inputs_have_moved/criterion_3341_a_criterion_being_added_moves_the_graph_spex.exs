defmodule CodeMySpecSpex.Story1063.Criterion3341Spex do
  @moduledoc """
  Story 1063 — A cached graph is never served after its inputs have moved.
  Criterion 3341 — A criterion being added moves the graph.

  Rule: a domain object we own publishes an event when it changes.

  Criteria are the input a Three Amigos session produces, a rule and its
  scenarios and its questions written in one breath. That burst is the reason
  the watcher debounces at all.

  They are also the input most easily missed by a hand-maintained list: criteria
  carry only a `story_id`, not a `project_id`, so the query that finds them is
  shaped differently from the one that finds stories or issues. An input whose
  linkage is irregular is exactly the one somebody forgets.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.ProjectStateFixtures

  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Adding a criterion moves the graph" do
    scenario "a scenario is added to a story" do
      given_ "a released story with a rule, and a graph that has been served", context do
        story = create_story(context.scope, title: "A story", description: "with a rule")

        frame = %Frame{assigns: %{current_scope: context.scope}}

        # A rule cannot be added to a story with no persona linked — the tool
        # refuses it, which is the Three Amigos protocol enforced at the
        # surface: persona first, then rules, then scenarios.
        context = ProjectStateFixtures.apply_persona(context)

        {:reply, link_response, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_id: story.id},
            frame
          )

        refute link_response.isError, inspect(link_response)

        {:reply, rule_response, _frame} =
          AddRule.execute(
            %{story_id: to_string(story.id), statement: "The thing holds."},
            frame
          )

        refute rule_response.isError, inspect(rule_response)

        before = read_settled_graph(context)

        assert satisfaction_of(before, "three_amigos_complete", :story, story.id) == false,
               """
               The premise did not hold: a rule with no scenario under it must
               leave `three_amigos_complete` open, or adding the scenario has
               nowhere to show up.

               three_amigos_complete: #{inspect(satisfaction_of(before, "three_amigos_complete", :story, story.id))}
               """

        {:ok,
         context
         |> Map.put(:new_story, story)
         |> Map.put(:before, before)}
      end

      when_ "a scenario is added under that rule", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AddScenario.execute(
            %{
              story_id: to_string(context.new_story.id),
              rule_statement: "The thing holds.",
              title: "The thing holds in the ordinary case",
              kind: "happy_path",
              body: "Given a thing\nWhen it is used\nThen it holds"
            },
            frame
          )

        refute response.isError,
               "the criterion must really be added for this to mean anything:\n" <>
                 inspect(response)

        {:ok, context}
      end

      then_ "the graph no longer says that rule has no scenarios", context do
        after_add = read_graph(context)

        reason = reason_for(after_add, "three_amigos_complete", :story, context.new_story.id)

        refute reason =~ "has no scenarios",
               """
               A criterion was added and the graph still says the rule it was
               added to has no scenarios.

               Criteria carry only a story_id, so the query that finds them is
               shaped differently from the one that finds stories or issues.
               An input whose linkage is irregular is the one a hand-maintained
               list forgets.

               The claim is the verdict, not a clock: a pass that ran and
               applied nothing moves `computed_at` exactly as far as one that
               worked, and `checked_at` is second-resolution besides.

               The verdict cannot carry this claim: `three_amigos_complete`
               stays false until the story is explicitly sealed, so it reads
               the same whether the scenario was added or not. What moves is
               the reason, and that is the effect the write had.

               reason before: #{inspect(reason_for(context.before, "three_amigos_complete", :story, context.new_story.id))}
               reason after:  #{inspect(reason)}
               """

        {:ok, context}
      end
    end
  end

end
