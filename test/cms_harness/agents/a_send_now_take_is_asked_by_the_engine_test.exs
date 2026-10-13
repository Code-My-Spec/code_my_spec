defmodule CmsHarness.Agents.ASendNowTakeIsAskedByTheEngineTest do
  @moduledoc """
  The send-now middleware's take reaches the channel from the agent's engine.

  The channel takes a mailbox request only from the engine (`Engine.whereis/1`
  against the caller). The middleware runs in the Alloy process, so asking the
  channel directly was refused as `:stale_engine` on every tool boundary, read
  as nothing sent, and a message sent now waited for the turn's end (team 2's
  coder, 2026-10-12). The specs passed because their agents take in-process.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Agents
  alias CmsHarness.Agents.Engine

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    CmsHarnessTest.Machine.ensure_supervisor()
    id = "agent-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Agents.launch(%{
        "agent_id" => id,
        "provider" => "deepinfra",
        "api_key" => "not-a-real-key",
        "working_copy" => root,
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "role" => "coding"
      })

    on_exit(fn -> Agents.halt(id) end)
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    %{id: id}
  end

  test "the middleware's take is asked by the engine, with its generation", %{id: id} do
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, id})
    %{alloy: alloy, generation: generation} = :sys.get_state(engine)
    take = :sys.get_state(alloy).config.context.take_send_now

    # From another process, as the middleware runs: the engine is the one that
    # reaches the channel, which is this test.
    asked = Task.async(take)

    assert_receive {:"$gen_call", {caller, _} = from,
                    {:mailbox, %{"operation" => "take_send_now", "agent_id" => ^id} = params}},
                   5_000

    assert {:ok, ^caller} = Engine.whereis(id)
    assert params["generation"] == generation

    GenServer.reply(from, {:ok, %{"messages" => ["Stop and merge main."]}})
    assert {:ok, %{"messages" => ["Stop and merge main."]}} = Task.await(asked)
  end
end
