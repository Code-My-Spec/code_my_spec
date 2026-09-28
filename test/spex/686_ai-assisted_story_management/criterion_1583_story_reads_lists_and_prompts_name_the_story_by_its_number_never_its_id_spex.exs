defmodule CodeMySpecSpex.Story686.Criterion1583Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 1583 — Story reads, lists and prompts name the story by its
  number, never its id.

  Covers Rule "Stories are named by their number and criteria by their number,
  everywhere." Showing a second identifier beside the number is how agents came
  to pass the wrong one back.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story is shown by its number alone", criterion: 1583 do
    scenario "the agent reads, lists and starts work on a story" do
      given_ "story A exists", context do
        story = CriterionScript.create_story(context.scope, "Story A", ["A thing happens"])
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the agent reads it, lists the backlog, and starts three amigos on it", context do
        read = CriterionScript.story_text(context.scope, context.story)
        listed = CriterionScript.run(context.scope, "return list_story_titles({})").text

        prompt =
          CriterionScript.run(
            context.scope,
            "return start_three_amigos_session({ story_number = #{context.story} })"
          ).text

        {:ok, Map.merge(context, %{read: read, listed: listed, prompt: prompt})}
      end

      then_ "each names story A by its number", context do
        assert context.read =~ "## Story #{context.story}: Story A", context.read
        assert context.listed =~ ~s("number": #{context.story}), context.listed
        refute context.listed =~ ~s("id":), context.listed
        assert context.prompt =~ "story_number", context.prompt

        {:ok, context}
      end

      and_ "none of them carries a story id", context do
        for text <- [context.read, context.listed, context.prompt] do
          refute text =~ "(ID: ", "a story id leaked:\n#{text}"
          refute text =~ "story_id", "a story_id leaked:\n#{text}"
        end

        {:ok, context}
      end
    end
  end
end
