defmodule CodeMySpecSpex.Story1016.Criterion1596Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1596 — An agent joining a working copy inherits the team's story

  The team on a working copy (its coding and QA agents) works one story
  together and moves on together; the main copy is promoted to, never worked
  on (a31f1cd6 step 3, John 2026-10-01).
  """
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An agent joining a working copy inherits the team's story", criterion: 1596 do
    scenario "An agent joining a working copy inherits the team's story" do
      given_ "a team working a story on this copy", context do
        {:ok, Slice.base(context)}
      end

      when_ "a new QA agent joins the copy", context do
        joiner = CodeMySpecSpex.Fixtures.running_agent(context.scope, role: "qa")
        {:ok, Map.put(context, :answer, Slice.next(context, %{agent_id: joiner.id}))}
      end

      then_ "it is working the team's story", context do
        assert context.answer =~ "# Story #{context.story.number}:",
               "a joining agent has to land on the story its team is on. Got:\n#{context.answer}"

        {:ok, context}
      end
    end
  end
end
