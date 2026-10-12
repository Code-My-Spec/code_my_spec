defmodule CodeMySpecSpex.Story1051.Criterion2149Spex do
  @moduledoc """
  Story 1051 — A message sent now to a busy agent arrives with the result of its next tool call, and the turn carries on.
  Rule: A message sent now reaches a busy agent at its next tool boundary, inside the running turn; nothing is cancelled.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a message sent now arrives with the next tool result", criterion: 2149 do
    scenario "main redirects a coder part-way through its turn" do
      given_ "a coder whose model is about to call a tool", ctx do
        {:ok, ctx |> H.start() |> H.mid_turn_before_a_tool_call()}
      end

      when_ "main sends it a message now, and the tool call runs", ctx do
        H.message(ctx, "STOP-AND-MERGE-MAIN", send_now: true)
        {:ok, H.boundary(ctx)}
      end

      then_ "the model's next request carries the tool's result and the message", ctx do
        request = H.after_the_tool_call(ctx)
        assert request =~ H.note(), "the tool call's result is missing: #{request}"
        assert request =~ "STOP-AND-MERGE-MAIN", "the message sent now never reached the model"
        {:ok, ctx}
      end

      then_ "the turn carries on rather than starting over", ctx do
        refute hd(HeldProvider.seen()) =~ "STOP-AND-MERGE-MAIN"
        assert length(HeldProvider.seen()) == 2
        {:ok, ctx}
      end
    end
  end
end
