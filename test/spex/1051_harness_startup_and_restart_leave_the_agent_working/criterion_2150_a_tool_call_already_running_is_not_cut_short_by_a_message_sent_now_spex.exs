defmodule CodeMySpecSpex.Story1051.Criterion2150Spex do
  @moduledoc """
  Story 1051 — A tool call already running is not cut short by a message sent now; the message arrives with that call's result.
  Rule: A message sent now reaches a busy agent at its next tool boundary, inside the running turn; nothing is cancelled.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a running tool call finishes before a message sent now arrives", criterion: 2150 do
    scenario "the message is sent while the turn is underway" do
      given_ "a coder part-way through a turn that calls a tool", ctx do
        {:ok, ctx |> H.start() |> H.mid_turn_before_a_tool_call()}
      end

      when_ "a message is sent now, and the call runs", ctx do
        H.message(ctx, "CHANGE-OF-PLAN", send_now: true)
        {:ok, H.boundary(ctx)}
      end

      then_ "the call's whole result comes back alongside the message", ctx do
        request = H.after_the_tool_call()
        assert request =~ H.note(), "the tool call was cut short: #{request}"
        assert request =~ "CHANGE-OF-PLAN"
        {:ok, ctx}
      end
    end
  end
end
