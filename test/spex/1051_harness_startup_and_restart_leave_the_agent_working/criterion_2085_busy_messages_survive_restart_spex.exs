defmodule CodeMySpecSpex.Story1051.Criterion2085Spex do
  use CodeMySpecSpex.Case
  alias CmsHarnessTest.HeldProvider
  alias CodeMySpec.Agents
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.MailboxHelpers, as: H
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "busy messages survive restart", criterion: 2085 do
    scenario "Durable mailbox authority" do
      given_ "a real engine is busy with two accepted waiting messages", ctx do
        ctx = ctx |> H.start() |> H.busy()

        assert {:ok, :queued} =
                 Agents.send_to_agent(ctx.agent.id, "first waiting", :operator_message)

        assert {:ok, :queued} =
                 Agents.send_to_agent(ctx.agent.id, "second waiting", :operator_message)

        {:ok, Map.put(ctx, :refs, Enum.map(H.entries(ctx), & &1.delivery_ref))}
      end

      when_ "the engine is replaced before either waiting message is consumed", ctx do
        Fixtures.halt_agent(ctx.agent.id)
        assert {:ok, _} = Fixtures.launch_agent(ctx.request)

        H.await(fn ->
          Enum.map(H.entries(ctx), & &1.state) == [:interrupted, :consumed, :queued]
        end)

        {:ok, ctx}
      end

      then_ "the same message identities execute in order with no engine payload queue", ctx do
        assert Enum.map(H.entries(ctx), & &1.delivery_ref) == ctx.refs
        assert {:ok, status} = Fixtures.agent_status(ctx.agent.id)
        refute Map.has_key?(status, :queued)
        HeldProvider.release()

        H.await(fn ->
          Enum.map(H.entries(ctx), & &1.state) == [:interrupted, :completed, :completed]
        end)

        texts = HeldProvider.seen()
        assert Enum.any?(texts, &String.contains?(&1, "first waiting"))
        assert Enum.any?(texts, &String.contains?(&1, "second waiting"))
        {:ok, ctx}
      end
    end
  end
end
