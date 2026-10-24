defmodule CodeMySpec.Promotion.RemotePublicationTransportTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Promotion.Runner

  test "an unreachable publication preserves the certified candidate for reconciliation" do
    assert {:error, %{unreachable: true, retryable: true, uncertain: true}} =
             Runner.publish(
               ExecutionContext.new(:harness, "/gate"),
               "/gate",
               "main",
               "base",
               "head",
               "promotion",
               Ecto.UUID.generate()
             )
  end

  test "a publication timeout and status-read failure are uncertain, not rejected" do
    for operation <- [:publish, :publication_status] do
      copy_id = Ecto.UUID.generate()
      parent = self()

      spawn_link(fn ->
        :ok = HarnessRegistry.register_executor(copy_id, "test", "/gate")
        send(parent, {:ready, copy_id})

        receive do
          {:"$gen_call", from, {:fs_request, op, _}} ->
            send(parent, {:operation, op})
            GenServer.reply(from, {:error, :timeout})
        end
      end)

      assert_receive {:ready, ^copy_id}

      assert {:error, %{retryable: true, uncertain: true}} =
               apply(Runner, operation, [
                 ExecutionContext.new(:harness, "/gate"),
                 "/gate",
                 "main",
                 "base",
                 "head",
                 "promotion",
                 copy_id
               ])

      expected = "promotion_#{operation}"
      assert_receive {:operation, ^expected}
    end
  end
end
