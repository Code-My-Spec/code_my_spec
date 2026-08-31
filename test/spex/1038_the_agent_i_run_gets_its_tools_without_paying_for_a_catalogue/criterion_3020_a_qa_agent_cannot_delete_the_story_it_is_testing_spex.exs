defmodule CodeMySpecSpex.Story1038.Criterion3020Spex do
  @moduledoc """
  Story 1038 — The agent I run gets its tools without paying for a catalogue.
  Criterion 3020 — A QA agent cannot delete the story it is testing.

  Rule: Each agent type reaches only the tools its job needs.

  The scoping has to survive code mode or it was never scoping. A QA agent that
  cannot call `delete_story` from a tool list, but can call it from inside a
  script, is scoped in the schemas and unscoped in fact — and the script is
  where an agent goes when the direct route is closed.

  The refusal has to name the reason. "Unknown tool" sends a QA agent looking
  for a typo in a name that exists, and it will find the name, and try again.

  And the story is still there afterwards, because a refusal that arrives after
  the delete is not a refusal.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentToolsHelpers

    alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Each agent type reaches only the tools its job needs" do
    scenario "A QA agent cannot delete the story it is testing" do
      given_ "a QA agent", context do
        id = running_agent(context, %{"role" => "qa"})
        story = Fixtures.authored_story(context.scope, "the story under test")

        {:ok, context |> Map.put(:agent_id, id) |> Map.put(:story, story)}
      end

      when_ "its script calls a tool its type does not carry", context do
        script = "return delete_story({ story_id = \"#{context.story.id}\" })"
        reply = Fixtures.run_script(script, agent_context(context))

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is refused and told the tool is not for its type", context do
        said = context.reply |> elem(1) |> to_string()

        assert said =~ ~r/qa/i and said =~ "delete_story",
               "the refusal does not say which tool was refused or which type was " <>
                 "refused it. An unknown-tool answer sends a QA agent hunting a typo in a " <>
                 "name that exists. Got: #{inspect(said)}"

        {:ok, context}
      end

      then_ "and the story is untouched", context do
        listed = Fixtures.run_script("return list_story_titles({})", agent_context(context))

        assert {:ok, body} = listed
        assert body =~ context.story.title,
               "the story was deleted and the refusal came afterwards, which is not " <>
                 "a refusal. Got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
