defmodule CodeMySpecSpex.Story1051.Criterion2153Spex do
  @moduledoc """
  Story 1051 — Messages not sent now still wait for the running turn to end, in order.
  Rule: A message sent now reaches a busy agent at its next tool boundary, inside the running turn; nothing is cancelled.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "an ordinary message still waits for the turn to end", criterion: 2153 do
    scenario "a message is queued while the agent works through a tool call" do
      given_ "a coder whose model is about to call a tool", ctx do
        {:ok, ctx |> H.start() |> H.mid_turn_before_a_tool_call()}
      end

      when_ "a message is sent without send now, and the call runs", ctx do
        H.message(ctx, "WAIT-FOR-THE-END")
        {:ok, H.boundary(ctx)}
      end

      then_ "the request after the call does not carry it", ctx do
        refute H.after_the_tool_call(ctx) =~ "WAIT-FOR-THE-END"
        {:ok, ctx}
      end

      then_ "it arrives once the turn has ended", ctx do
        H.await(fn -> Enum.any?(HeldProvider.seen(), &(&1 =~ "WAIT-FOR-THE-END")) end)
        {:ok, ctx}
      end
    end
  end
end
