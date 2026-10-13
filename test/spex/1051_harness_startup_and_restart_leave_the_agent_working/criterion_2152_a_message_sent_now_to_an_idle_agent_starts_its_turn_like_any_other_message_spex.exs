defmodule CodeMySpecSpex.Story1051.Criterion2152Spex do
  @moduledoc """
  Story 1051 — A message sent now to an idle agent starts its turn like any other message.
  Rule: A message sent now reaches a busy agent at its next tool boundary, inside the running turn; nothing is cancelled.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "an idle agent starts on a message sent now", criterion: 2152 do
    scenario "nothing is running when main sends now" do
      given_ "an idle coder", ctx do
        {:ok, H.start(ctx)}
      end

      when_ "main sends it a message now", ctx do
        {:ok, Map.put(ctx, :reply, H.message(ctx, "START-ON-THIS", send_now: true))}
      end

      then_ "the agent starts its turn on it", ctx do
        assert ctx.reply =~ "The agent has started its turn", ctx.reply
        H.await(fn -> Enum.any?(HeldProvider.seen(), &(&1 =~ "START-ON-THIS")) end)
        {:ok, ctx}
      end
    end
  end
end
