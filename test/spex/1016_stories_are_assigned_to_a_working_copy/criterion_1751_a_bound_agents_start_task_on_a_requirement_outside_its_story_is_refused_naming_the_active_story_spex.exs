defmodule CodeMySpecSpex.Story1016.Criterion1751Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1751 — A bound agent's start_task on a requirement outside its story is
  refused, naming the active story.

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

  spex "A bound agent cannot claim project work", criterion: 1751 do
    scenario "the coder tries to take the project-wide issues" do
      given_ "a team on its story and an accepted project issue", context do
        {:ok, context |> team_on_a_story() |> issue_accepted()}
      end

      when_ "the coding agent starts project-level issues_resolved", context do
        {:ok,
         Map.put(context, :result, start_project(context, context.coding, "issues_resolved"))}
      end

      then_ "it is refused, naming the story it is on", context do
        {error?, text} = context.result
        assert error?, "a story-bound agent claimed project work: #{text}"
        assert text =~ "active story #{context.story.number}"
        {:ok, context}
      end
    end
  end
end
