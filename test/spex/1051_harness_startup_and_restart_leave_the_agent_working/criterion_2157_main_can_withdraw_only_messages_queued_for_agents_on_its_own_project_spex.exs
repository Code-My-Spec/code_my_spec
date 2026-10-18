defmodule CodeMySpecSpex.Story1051.Criterion2157Spex do
  @moduledoc """
  Story 1051 — Main can withdraw only messages queued for agents on its own project.
  Rule: Main and the operator can withdraw a message they queued, with the same single winner as the cockpit's Withdraw.
  """
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "main cannot withdraw on another project", criterion: 2157 do
    scenario "a message queued for an agent on a different project" do
      given_ "a busy coder with a message queued, and main on another project", ctx do
        ctx = ctx |> H.start() |> H.busy()
        id = H.message_id(H.message(ctx, "NOT-YOURS"))

        {:ok,
         Map.merge(ctx, %{id: id, elsewhere: Fixtures.other_project_scope(ctx.scope, "Elsewhere")})}
      end

      when_ "main on the other project tries to withdraw it", ctx do
        {:ok, Map.put(ctx, :response, H.withdraw(ctx.elsewhere, ctx.agent.id, ctx.id))}
      end

      then_ "it is refused, and the message still reaches the agent", ctx do
        assert match?({:error, _}, ctx.response)
        assert H.text_of(ctx.response) =~ "No agent with that id is on this project"
        HeldProvider.release()
        H.await(fn -> Enum.any?(HeldProvider.seen(), &(&1 =~ "NOT-YOURS")) end)
        {:ok, ctx}
      end
    end
  end
end
