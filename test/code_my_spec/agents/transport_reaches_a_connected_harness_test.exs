defmodule CodeMySpec.Agents.TransportReachesAConnectedHarnessTest do
  @moduledoc """
  The real transport, against the registry a real join populates.

  This exists because the module shipped looking up
  `CodeMySpecWeb.HarnessRegistry` — which is not a module anywhere. The real one
  is `CodeMySpec.Analysis.HarnessRegistry`. Every `Registry.lookup/2` raised, a
  `rescue ArgumentError -> :none` turned that into `:harness_not_connected`, and
  every start and every stop reported the machine unreachable in every
  environment — including with a harness connected and reconciling that exact
  working copy a second earlier.

  Nothing caught it. Every spex in story 1023 swaps the transport for an
  in-process implementation so it can drive real processes, which is right for
  what those criteria are about and means the real module was never exercised by
  anything. A seam that every test replaces is a seam nothing tests.

  So this drives `Transport.Harness` itself and asserts only what it is for:
  that it finds a connected copy and does not find an absent one. What happens
  on the far side is the round-trip test's subject.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Analysis

  defp agent_for(scope) do
    %Agent{
      id: Ecto.UUID.generate(),
      working_copy_id: scope.active_working_copy_id,
      os_pid: 4242,
      os_boot_id: "boot-abc",
      engine: :alloy,
      provider: "zai",
      role: "coding",
      working_copy: "/tmp/a-copy"
    }
  end

  test "a copy nothing is holding is reported unreachable" do
    scope = full_scope_fixture()

    assert {:error, :harness_not_connected} =
             Transport.Harness.stop_agent(scope.active_working_copy_id, agent_for(scope), 100)
  end

  test "a connected copy is found, rather than reported unreachable" do
    scope = full_scope_fixture()

    # What a channel join does: register this process as the executor holding
    # the copy. `register_executor/3` is the same call
    # `HarnessProjectChannel` makes.
    :ok = register_holder(scope.active_working_copy_id)

    # The transport reaches us. We are not a channel, so the call fails on the
    # far side rather than being refused before it leaves — and *that* is the
    # distinction under test. `:harness_not_connected` here would mean the
    # lookup never found a live holder, which is the shipped defect.
    result =
      Transport.Harness.stop_agent(scope.active_working_copy_id, agent_for(scope), 100)

    refute result == {:error, :harness_not_connected},
           "the transport could not find a copy that is registered and held by a " <>
             "live process. That is the whole defect: it looked up a registry " <>
             "module that does not exist, a rescue turned the raise into " <>
             "`:harness_not_connected`, and every stop in every environment " <>
             "reported the machine unreachable."
  end

  # Registers the calling process against this copy, the way a join does.
  # Spawned rather than done inline where a live pid is needed, because the
  # caller has to stay free to make the transport call.
  defp register_holder(working_copy_id) do
    test = self()

    {:ok, _pid} =
      Task.start_link(fn ->
        Analysis.register_executor(working_copy_id, self(), "/tmp/a-copy")
        send(test, :registered)
        Process.sleep(:infinity)
      end)

    receive do
      :registered -> :ok
    after
      2_000 -> flunk("the holder never registered")
    end
  end
end
