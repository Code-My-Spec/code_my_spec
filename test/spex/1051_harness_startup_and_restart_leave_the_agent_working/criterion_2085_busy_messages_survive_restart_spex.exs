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

        # The cut turn's entry is complete, the waiting two hold their places,
        # and the carry-on is the one the new engine took.
        H.await(fn ->
          Enum.map(H.entries(ctx), & &1.state) == [:completed, :queued, :queued, :consumed]
        end)

        {:ok, ctx}
      end

      then_ "the cut turn carries on, then the same message identities execute in order", ctx do
        assert H.entries(ctx) |> Enum.map(& &1.delivery_ref) |> Enum.take(3) == ctx.refs
        assert {:ok, status} = Fixtures.agent_status(ctx.agent.id)
        refute Map.has_key?(status, :queued)
        HeldProvider.release()

        H.await(fn ->
          Enum.map(H.entries(ctx), & &1.state) == [:completed, :completed, :completed, :completed]
        end)

        texts = HeldProvider.seen()
        at = fn text -> Enum.find_index(texts, &String.contains?(&1, text)) end

        assert at.("Carry on from your last step") < at.("first waiting"),
               "a waiting message went before the turn it was queued behind"

        assert at.("first waiting") < at.("second waiting")
        {:ok, ctx}
      end
    end
  end
end
