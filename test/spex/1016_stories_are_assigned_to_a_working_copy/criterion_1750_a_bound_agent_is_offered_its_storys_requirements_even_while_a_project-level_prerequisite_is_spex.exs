defmodule CodeMySpecSpex.Story1016.Criterion1750Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1750 — A bound agent is offered its story's requirements even while a
  project-level prerequisite is unsatisfied; project-level prerequisites are
  offered to main and product.

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

  spex "Project prerequisites do not hold a bound agent's story back", criterion: 1750 do
    scenario "the project's QA plan goes missing while QA's story work is open" do
      given_ "a team on its story, whose project QA setup is unsatisfied again", context do
        {:ok, context |> team_on_a_story() |> qa_plan_missing()}
      end

      when_ "the QA agent asks what to do next", context do
        {:ok, Map.put(context, :text, next_for(context, context.qa))}
      end

      then_ "it is offered its story's QA, not the project's QA setup", context do
        assert offers?(context.text, "qa_complete"), context.text
        refute offers?(context.text, "qa_setup"), context.text
        {:ok, context}
      end
    end
  end
end
