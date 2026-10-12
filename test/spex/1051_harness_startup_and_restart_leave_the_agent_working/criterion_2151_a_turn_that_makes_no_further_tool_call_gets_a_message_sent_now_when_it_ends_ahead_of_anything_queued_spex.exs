defmodule CodeMySpecSpex.Story1051.Criterion2151Spex do
  @moduledoc """
  Story 1051 — A turn that makes no further tool call gets a message sent now when it ends, ahead of anything queued.
  Rule: A message sent now reaches a busy agent at its next tool boundary, inside the running turn; nothing is cancelled.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a message sent now goes first when the turn ends", criterion: 2151 do
    scenario "the turn answers without calling a tool" do
      given_ "a busy coder with one message queued for the turn's end", ctx do
        ctx = ctx |> H.start() |> H.busy()
        H.message(ctx, "QUEUED-EARLIER")
        {:ok, ctx}
      end

      when_ "another is sent now and the turn ends with no tool call", ctx do
        H.message(ctx, "SENT-NOW-LATER", send_now: true)
        HeldProvider.release()
        H.await(fn -> Enum.any?(HeldProvider.seen(), &(&1 =~ "QUEUED-EARLIER")) end)
        {:ok, ctx}
      end

      then_ "the message sent now reaches the model before the queued one", ctx do
        seen = HeldProvider.seen()
        now = Enum.find_index(seen, &(&1 =~ "SENT-NOW-LATER"))
        queued = Enum.find_index(seen, &(&1 =~ "QUEUED-EARLIER"))
        assert now && now < queued, "sent now at #{inspect(now)}, queued at #{queued}"
        {:ok, ctx}
      end
    end
  end
end
