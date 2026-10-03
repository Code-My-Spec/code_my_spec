defmodule CodeMySpecSpex.Story1016.Criterion1753Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1753 — When the active story isn't ready or is reserved elsewhere, the agent is
  offered nothing and is told which story is unavailable.

  John (4292518a): an agent whose copy has an active story is bound by it.
  It is offered only what it is responsible for — the story's own
  requirements, issues filed against the story, the story's components —
  and project-level work goes to main and product.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.StoryBoundHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An unavailable story offers nothing and says which", criterion: 1753 do
    scenario "the team's story is taken out of development" do
      given_ "a team on its story, and an accepted project issue", context do
        {:ok, context |> team_on_a_story() |> issue_accepted()}
      end

      when_ "the story is marked not ready for development", context do
        CodeMySpecSpex.StorySliceHelpers.call(
          context,
          CodeMySpec.McpServers.Stories.Tools.UpdateStory,
          %{story_number: context.story.number, ready_for_dev: false}
        )

        {:ok, Map.put(context, :text, next_for(context, context.coding))}
      end

      then_ "the coder is offered nothing, and told which story is unavailable", context do
        refute context.text =~ "requirement_name=", context.text
        assert context.text =~ "#{context.story.number}", context.text
        refute offers?(context.text, "issues_resolved"), context.text
        {:ok, context}
      end
    end
  end
end
