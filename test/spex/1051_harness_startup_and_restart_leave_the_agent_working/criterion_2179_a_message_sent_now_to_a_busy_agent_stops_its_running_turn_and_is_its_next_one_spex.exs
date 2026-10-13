defmodule CodeMySpecSpex.Story1051.Criterion2179Spex do
  @moduledoc """
  Story 1051 — A message sent now to a busy agent stops its running turn and is
  its next one; the agent carries on holding everything it did up to its last
  completed tool call.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a message sent now stops the turn and is the next one", criterion: 2179 do
    scenario "main corrects a coder part-way through its turn" do
      given_ "a coder mid-turn, one tool call done and its model working on the next step",
             ctx do
        {:ok,
         ctx
         |> H.start()
         |> H.mid_turn_before_a_tool_call()
         |> H.still_working_after_a_tool_call()}
      end

      when_ "main sends it a message now", ctx do
        before = length(HeldProvider.seen())
        H.message(ctx, "STOP-AND-MERGE-MAIN", send_now: true)
        H.await(fn -> length(HeldProvider.seen()) > before end)
        {:ok, Map.put(ctx, :next, Enum.at(HeldProvider.seen(), before))}
      end

      then_ "the model's next request carries the message, without waiting for the turn",
            ctx do
        assert ctx.next =~ "STOP-AND-MERGE-MAIN", "the message sent now did not come next"
        assert ctx.next =~ "stopped part-way through this turn"
        {:ok, ctx}
      end

      then_ "and still holds what the agent did before it was stopped", ctx do
        assert ctx.next =~ H.note(), "the completed tool call's result was lost: #{ctx.next}"
        {:ok, ctx}
      end
    end
  end
end
