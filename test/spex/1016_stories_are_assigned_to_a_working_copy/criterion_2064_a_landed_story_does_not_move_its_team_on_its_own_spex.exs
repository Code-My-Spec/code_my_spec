defmodule CodeMySpecSpex.Story1016.Criterion2064Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 2064 — When a team's story lands, the team is not moved to another
  story on its own; the main agent is told the team is free.

  John, 2026-10-07: the automatic rebinding is retired. A team keeps one story
  until it lands, and landing does not pull the team anywhere — the move is
  always an agent's act. What the landing produces instead is the `:team_free`
  signal to main, so main knows a team is available and assigns the next story
  itself (criterion 2065).

  This spec exits for the behaviour that replaced criterion 1600/1752, which
  product retired with the rebinding. The scenario therefore has a *second*
  story waiting: under the old rule the team would have been moved onto it the
  moment the first landed, so an eligible next story is exactly what makes the
  assertion mean something.

  Observed through the real surface — the coding agent's own
  `get_next_requirement` — because the old defect was a read moving the team.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A landed story does not move its team on its own", criterion: 2064 do
    scenario "the team's story lands and another story is ready" do
      given_ "a team whose story has landed, and another story waiting", context do
        context = context |> Slice.staff() |> Slice.complete() |> Slice.waiting()
        context = Slice.land(context)
        {:ok, context}
      end

      when_ "the coding agent asks what to work on", context do
        [coding, qa] = context.team
        answer = Slice.next(context, %{agent_id: coding.id})
        {:ok, Map.merge(context, %{answer: answer, qa: qa})}
      end

      then_ "it is not moved onto the waiting story", context do
        refute context.answer =~ "# Story #{context.waiting.number}:",
               "the team was moved to its next story automatically. Got:\n#{context.answer}"

        {:ok, context}
      end

      then_ "and neither is the rest of the team", context do
        refute Slice.next(context, %{agent_id: context.qa.id}) =~
                 "# Story #{context.waiting.number}:",
               "the QA agent's own read moved the team to its next story."

        {:ok, context}
      end
    end
  end
end
