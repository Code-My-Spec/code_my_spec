defmodule CodeMySpecSpex.Story1016.Criterion1749Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1749 — A coding or QA agent with an active story is offered only that story's
  requirements, including issues filed against it, and never project-level
  issues_resolved or another story's work.

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

  spex "A bound coder is offered its story's work, not the project's", criterion: 1749 do
    scenario "an accepted issue on the project, and one filed against the story" do
      given_ "a team on its story, an accepted project issue, and an issue filed against the story",
             context do
        context = team_on_a_story(context)
        context = issue_accepted(context)
        {:ok, issue_accepted(context, context.story)}
      end

      when_ "the coding agent asks what to do next", context do
        {:ok, Map.put(context, :text, next_for(context, context.coding))}
      end

      then_ "it is offered the story's issue, on its story", context do
        assert context.text =~ "# Story #{context.story.number}:"
        assert offers?(context.text, "story_issues_resolved"), context.text
        {:ok, context}
      end

      then_ "and never the project-wide issues_resolved", context do
        refute offers?(context.text, "issues_resolved"), context.text
        {:ok, context}
      end
    end
  end
end
