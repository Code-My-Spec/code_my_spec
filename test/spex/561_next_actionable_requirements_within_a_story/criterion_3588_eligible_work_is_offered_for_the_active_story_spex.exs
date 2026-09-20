defmodule CodeMySpecSpex.Story561.Criterion3588Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3588 — Eligible work is offered for the active story
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Eligible work is offered for the active story" do
    scenario "Eligible work is offered for the active story" do
      given_ "a story whose component has no implementation yet", context do
        context = context |> Slice.base() |> Slice.child()
        {:ok, context}
      end

      when_ "the agent asks what to work on", context do
        agent = CodeMySpecSpex.Fixtures.running_agent(context.scope, role: "coding")
        {:ok, Map.put(context, :answer, Slice.next(context, %{agent_id: agent.id}))}
      end

      then_ "the missing implementation is offered as this story's work", context do
        Slice.assert_active(context.answer, context, "ready")
        assert Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        {:ok, context}
      end
    end
  end
end
