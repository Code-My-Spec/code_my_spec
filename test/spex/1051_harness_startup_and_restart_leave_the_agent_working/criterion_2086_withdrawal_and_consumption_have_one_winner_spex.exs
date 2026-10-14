defmodule CodeMySpecSpex.Story1051.Criterion2086Spex do
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpec.Agents
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "withdrawal and consumption have one winner", criterion: 2086 do
    scenario "Durable mailbox authority" do
      given_ "delivery is claimed but its transport acknowledgement is missing", ctx do
        ctx = H.start(ctx)
        H.transport(ctx, H.Unconfirmed)

        assert {:error, :message_timed_out} =
                 Agents.send_to_agent(ctx.agent.id, "withdraw this", :operator_message)

        assert [%{state: :claimed} = entry] = H.entries(ctx)
        {:ok, Map.put(ctx, :entry, entry)}
      end

      when_ "withdrawal wins before a delayed engine receives the claim", ctx do
        assert {:ok, _} = Agents.withdraw_message(ctx.scope, ctx.agent.id, ctx.entry.delivery_ref)

        assert {:error, _} =
                 CmsHarnessTest.Machine.send_message(
                   ctx.agent.id,
                   ctx.entry.delivery_ref,
                   "withdraw this"
                 )

        assert HeldProvider.seen() == []
        {:ok, ctx}
      end

      then_ "a later message consumed first cannot be withdrawn", ctx do
        H.transport(ctx, CodeMySpecTest.InProcessAgentTransport)
        HeldProvider.hold()

        assert {:ok, :started} =
                 Agents.send_to_agent(ctx.agent.id, "consumed first", :operator_message)

        HeldProvider.await_request()
        entry = List.last(H.entries(ctx))

        assert {:error, :already_delivered} =
                 Agents.withdraw_message(ctx.scope, ctx.agent.id, entry.delivery_ref)

        HeldProvider.release()
        H.await(fn -> List.last(H.entries(ctx)).state == :completed end)
        {:ok, ctx}
      end
    end
  end
end
