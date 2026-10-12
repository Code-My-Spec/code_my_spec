defmodule CodeMySpecSpex.Story1051.Criterion2155Spex do
  @moduledoc """
  Story 1051 — Main withdraws a message it queued for one of its agents before the agent takes it, and the agent never sees it.
  Rule: Main and the operator can withdraw a message they queued, with the same single winner as the cockpit's Withdraw.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "main takes back a queued message", criterion: 2155 do
    scenario "main changes its mind while the coder is busy" do
      given_ "a busy coder with main's message queued", ctx do
        ctx = ctx |> H.start() |> H.busy()
        {:ok, Map.put(ctx, :id, H.message_id(H.message(ctx, "NEVER-MIND-THIS")))}
      end

      when_ "main withdraws it and the turn ends", ctx do
        response = H.withdraw(ctx.scope, ctx.agent.id, ctx.id)
        HeldProvider.release()
        H.await(fn -> Enum.all?(H.entries(ctx), &(&1.state in [:completed, :withdrawn])) end)
        {:ok, Map.put(ctx, :response, response)}
      end

      then_ "the withdrawal is confirmed and the agent never sees the message", ctx do
        refute ctx.response.isError, H.text_of(ctx.response)
        refute Enum.any?(HeldProvider.seen(), &(&1 =~ "NEVER-MIND-THIS"))
        {:ok, ctx}
      end
    end
  end
end
