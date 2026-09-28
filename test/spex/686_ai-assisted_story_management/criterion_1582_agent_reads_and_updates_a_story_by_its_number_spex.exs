defmodule CodeMySpecSpex.Story686.Criterion1582Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 1582 — Agent reads and updates a story by its number.

  Covers Rule "Stories are named by their number and criteria by their number,
  everywhere." The number is the only handle the agent is given, so it is the
  one every story tool takes.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story is read and updated by its number", criterion: 1582 do
    scenario "the agent renames a story it knows by number" do
      given_ "story A exists", context do
        story = CriterionScript.create_story(context.scope, "Story A", [])
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent updates story A's title by its number", context do
        result =
          CriterionScript.run(context.scope, """
          return update_story({ story_number = #{context.story}, title = "Story A, renamed" })
          """)

        refute result.error?, "update_story failed: #{result.text}"
        {:ok, context}
      end

      then_ "reading story A by its number shows the new title", context do
        text = CriterionScript.story_text(context.scope, context.story)

        assert text =~ "## Story #{context.story}: Story A, renamed",
               "expected the renamed story under its number. Got:\n#{text}"

        {:ok, context}
      end
    end
  end
end
