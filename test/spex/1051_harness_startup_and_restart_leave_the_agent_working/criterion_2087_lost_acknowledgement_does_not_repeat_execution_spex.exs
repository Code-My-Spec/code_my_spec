defmodule CodeMySpecSpex.Story1051.Criterion2087Spex do
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "lost acknowledgement does not repeat execution", criterion: 2087 do
    scenario "Durable mailbox authority" do
      given_ "the real engine consumes a message but its acknowledgement is lost", ctx do
        ctx = H.start(ctx)
        H.transport(H.LostAck)
        HeldProvider.hold()

        assert {:ok, :started} =
                 Agents.send_to_agent(ctx.agent.id, "execute once", :operator_message)

        HeldProvider.await_request()
        {:ok, ctx}
      end

      when_ "delivery reconciliation and a duplicate dispatch run", ctx do
        assert [entry] = H.entries(ctx)
        assert {:ok, :queued} = Mailbox.pump(ctx.scope, ctx.agent.id)
        HeldProvider.release()
        H.await(fn -> List.first(H.entries(ctx)).state == :completed end)

        assert {:error, _} =
                 CmsHarnessTest.Machine.send_message(
                   ctx.agent.id,
                   entry.delivery_ref,
                   "execute once"
                 )

        {:ok, ctx}
      end

      then_ "one durable identity authorized only one model execution", ctx do
        assert [%{state: :completed}] = H.entries(ctx)
        assert length(HeldProvider.seen()) == 1
        {:ok, ctx}
      end
    end
  end
end
