defmodule CodeMySpecSpex.Story1016.Criterion1752Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1752 — When the active story is complete, the team moves to the next eligible
  story; with none, nothing is offered and there is no fallback to project
  work.

  John (4292518a): an agent whose copy has an active story is bound by it.
  It is offered only what it is responsible for — the story's own
  requirements, issues filed against the story, the story's components —
  and project-level work goes to main and product.

  "Complete" here means *landed*: the story is finished and promoted. John,
  2026-10-06 (issue f0c18598): a team's story stays until it lands, so the
  scenario lands it (`Slice.land/1`) before asking what comes next. A story
  that is finished but unpromoted keeps its team instead — see criterion 1600.
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

  spex "A finished story with nothing after it leaves the team idle", criterion: 1752 do
    scenario "the team's story is done and no other story is eligible" do
      given_ "a team whose story is complete, and an accepted project issue", context do
        context =
          context
          |> CodeMySpecSpex.StorySliceHelpers.complete()
          |> CodeMySpecSpex.StorySliceHelpers.land()
          |> issue_accepted()
        [coding | _] = context.team
        {:ok, Map.put(context, :coding, coding)}
      end

      when_ "the coding agent asks what to do next", context do
        {:ok, Map.put(context, :text, next_for(context, context.coding))}
      end

      then_ "its story reads complete, and it is not handed the project's issues", context do
        assert context.text =~ "Status: complete", context.text
        refute offers?(context.text, "issues_resolved"), context.text
        {:ok, context}
      end
    end
  end
end
