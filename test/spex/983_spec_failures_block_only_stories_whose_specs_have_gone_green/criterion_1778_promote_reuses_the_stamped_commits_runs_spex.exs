defmodule CodeMySpecSpex.Story983.Criterion1778Spex do
  @moduledoc """
  Story 983 — Criterion 1778: promoting a story whose HEAD is still its ready-for-QA commit reuses that
  commit's clean runs; if main has moved, the merge commit is analysed afresh.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.PromotionHelpers
  import CodeMySpecSpex.ReadyForQaHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  alias CodeMySpec.Analysis.RunsRepository

  defp runs_on(context, copy) do
    scope = %{context.scope | active_working_copy_id: copy.working_copy_id}
    Enum.flat_map(~w(compiler credo exunit spex), &RunsRepository.running_full_runs(scope, &1))
  end

  spex "A certified commit promotes on the runs that certified it", criterion: 1778 do
    scenario "nothing changed since the story was certified" do
      given_ "a story certified ready for QA through its held task", context do
        context = context |> a_promotable_project() |> analyzers_are_current()
        story = a_promotable_story(context)
        context = a_held_ready_for_qa_task(context, story)
        {false, _} = complete_ready_for_qa(context)
        {:ok, Map.put(context, :story, story)}
      end

      when_ "the story is promoted", context do
        {:ok, Map.put(context, :response, promote(context, context.story.number))}
      end

      then_ "it merges, and no new run was started on the copy", context do
        refute context.response.isError, inspect(context.response)
        assert runs_on(context, context.agent) == []
        {:ok, context}
      end
    end
  end
end
