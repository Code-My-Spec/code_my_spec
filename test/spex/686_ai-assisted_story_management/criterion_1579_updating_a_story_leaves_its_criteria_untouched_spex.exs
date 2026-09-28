defmodule CodeMySpecSpex.Story686.Criterion1579Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 1579 — Updating a story leaves its criteria untouched.

  Covers Rule "The agent can create, read, update, and retire stories within
  the active project." Criteria change only through the criterion tools, so
  each keeps its number for life. `update_story` rebuilding the list is how
  story 1100's criteria were renumbered and lost their specs.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.ToolDocs
  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "update_story does not touch criteria", criterion: 1579 do
    scenario "the agent updates a story's title and description" do
      given_ "story A has two criteria", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A first thing", "A second thing"])
        numbers = context.scope |> CriterionScript.story_text(story) |> CriterionScript.numbers()
        {:ok, context |> Map.put(:story, story) |> Map.put(:numbers, numbers)}
      end

      when_ "the agent updates story A's title and description", context do
        result =
          CriterionScript.run(context.scope, """
          return update_story({ story_id = "#{context.story}", title = "Story A, renamed", description = "Clearer" })
          """)

        refute result.error?, "update_story failed: #{result.text}"
        {:ok, context}
      end

      then_ "story A still has the same criteria", context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert CriterionScript.numbers(text) == context.numbers,
               "expected criteria #{inspect(context.numbers)} untouched. get_story showed:\n#{text}"

        {:ok, context}
      end

      and_ "update_story offers no way to replace them", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ToolDocs.execute(%{name: "update_story"}, frame)
        docs = response_text(response)

        assert docs =~ "update_story", "anchor: expected update_story's docs. Got:\n#{docs}"

        refute docs =~ "acceptance_criteria",
               "update_story still takes acceptance_criteria, so it can replace a story's criteria. Got:\n#{docs}"

        {:ok, context}
      end
    end
  end
end
