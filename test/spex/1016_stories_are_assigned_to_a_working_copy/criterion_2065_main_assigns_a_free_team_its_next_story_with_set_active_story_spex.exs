defmodule CodeMySpecSpex.Story1016.Criterion2065Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 2065 — The main agent assigns a free team its next story with
  `set_active_story`, from the team's queue.

  The other half of retiring the rebinding (criterion 2064): nothing moves a
  team automatically, so an explicit assignment is the only way it moves. Main
  is the agent that makes it, and `set_active_story` is the tool — the same one
  issue e21ab16c corrected the team-free notice to name.

  What makes this worth asserting rather than assuming: the old defect was that
  `set_active_story` did *not* stick. The main agent ran it four times, each
  returned success, and the team was pulled off the story anyway within about a
  minute (issue f0c18598). So the assertion is not just that the tool returns
  success but that the binding survives the team's own next read — which is the
  read that used to undo it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main assigns a free team its next story, and it sticks", criterion: 2065 do
    scenario "a team is free and main points it at the next story" do
      given_ "a free team and a waiting story on main's queue", context do
        context = context |> Slice.staff() |> Slice.waiting() |> Slice.main_copy()
        {:ok, context}
      end

      when_ "main assigns the team that story with set_active_story", context do
        answer =
          Slice.call(context, "set_active_story", %{
            story_number: context.waiting.number,
            working_copy_id: context.scope.active_working_copy_id
          })

        {:ok, Map.merge(context, %{assign: answer})}
      end

      then_ "the assignment is accepted", context do
        assert context.assign =~ "#{context.waiting.number}",
               "set_active_story did not confirm the assignment. Got:\n#{context.assign}"

        {:ok, context}
      end

      then_ "and the team stays on that story when it reads for itself", context do
        [coding, _qa] = context.team
        answer = Slice.next(context, %{agent_id: coding.id})

        assert answer =~ "# Story #{context.waiting.number}:",
               "the team did not stay on the story main assigned. Got:\n#{answer}"

        {:ok, context}
      end
    end
  end
end
