defmodule CodeMySpecSpex.Story561.Criterion3604Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3604 — A blocked story is not a completed story
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A blocked story is not a completed story", criterion: 1502 do
    scenario "A blocked story is not a completed story" do
      given_ "a story whose remaining work is blocked rather than finished", context do
        context =
          context
          |> Slice.base()
          |> Slice.child()
          |> Slice.waiting(module: "Reservations", bdd: false)

        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "the answer is blocked, which is not the same as complete", context do
        Slice.assert_active(context.answer, context, "blocked")
        assert context.answer =~ "bdd_specs_exist"
        refute context.answer =~ "requirement_name=`"
        refute context.answer =~ "Status: complete"
        {:ok, context}
      end
    end
  end
end
