defmodule CodeMySpecSpex.Story1051.Criterion2156Spex do
  @moduledoc """
  Story 1051 — Withdrawing a message the agent has already taken is refused as already delivered.
  Rule: Main and the operator can withdraw a message they queued, with the same single winner as the cockpit's Withdraw.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a message the agent has is not withdrawn", criterion: 2156 do
    scenario "main reaches for it after the turn took it" do
      given_ "main's message, queued and then taken when the turn ended", ctx do
        ctx = ctx |> H.start() |> H.busy()
        id = H.message_id(H.message(ctx, "ALREADY-TAKEN"))
        HeldProvider.release()
        H.await(fn -> Enum.any?(HeldProvider.seen(), &(&1 =~ "ALREADY-TAKEN")) end)
        {:ok, Map.put(ctx, :id, id)}
      end

      when_ "main tries to withdraw it", ctx do
        {:ok, Map.put(ctx, :response, H.withdraw(ctx.scope, ctx.agent.id, ctx.id))}
      end

      then_ "it is refused as already delivered", ctx do
        assert match?({:error, _}, ctx.response)
        assert H.text_of(ctx.response) =~ "already has this message"
        {:ok, ctx}
      end
    end
  end
end
