defmodule CodeMySpecSpex.Story1016.Criterion1754Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1754 — An agent without an active story, and main and product, are offered
  project-level work as before.

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

  spex "Project work goes to an agent with no active story", criterion: 1754 do
    scenario "a coder whose copy has no active story" do
      given_ "a coder on a copy with no active story, and an accepted project issue", context do
        {:ok, context |> team_on_a_story(active?: false) |> issue_accepted()}
      end

      when_ "the coding agent asks what to do next", context do
        {:ok, Map.put(context, :text, next_for(context, context.coding))}
      end

      then_ "it is offered the project-wide issues_resolved", context do
        assert offers?(context.text, "issues_resolved"), context.text
        {:ok, context}
      end
    end
  end
end
