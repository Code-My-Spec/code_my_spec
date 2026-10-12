defmodule CodeMySpecSpex.Story1051.Criterion2088Spex do
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpec.Agents
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "accepted sources share one mailbox", criterion: 2088 do
    scenario "Durable mailbox authority" do
      given_ "Main is busy when several message sources address it", ctx do
        Fixtures.designate_main(ctx.scope, ctx.scope.active_working_copy_id)
        ctx = ctx |> H.start(:main) |> H.busy()
        {:ok, ctx}
      end

      when_ "an operator, an answer and a team notification are accepted", ctx do
        assert {:ok, :queued, _} =
                 Agents.dispatch_message(ctx.scope, ctx.agent.id, "operator", :operator_message)

        assert {:ok, :queued} =
                 Agents.send_to_agent(ctx.agent.id, "answer", :question_answered,
                   offer: {:answer, {"question", "one"}}
                 )

        assert :ok =
                 Agents.notify_main(ctx.scope, :team_free, "team notification",
                   offer: {:team_free, {"working_copy", ctx.scope.active_working_copy_id}}
                 )

        {:ok, ctx}
      end

      then_ "they are ordered in the same durable mailbox before any can execute", ctx do
        assert Enum.map(H.entries(ctx), & &1.event) == [
                 "operator_message",
                 "operator_message",
                 "question_answered",
                 "team_free"
               ]

        assert Enum.map(H.entries(ctx), & &1.state) == [:consumed, :queued, :queued, :queued]
        assert {:ok, status} = Fixtures.agent_status(ctx.agent.id)
        refute Map.has_key?(status, :queued)
        HeldProvider.release()
        H.await(fn -> Enum.all?(H.entries(ctx), &(&1.state == :completed)) end)
        {:ok, ctx}
      end
    end
  end
end
