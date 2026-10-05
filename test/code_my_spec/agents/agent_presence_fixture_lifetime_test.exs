defmodule CodeMySpecTest.AgentPresenceFixtureLifetimeTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Presence
  alias CodeMySpecTest.AgentPresence

  test "the presence holder exits when its scenario owner exits normally" do
    agent = %{id: Ecto.UUID.generate(), project_id: Ecto.UUID.generate()}
    parent = self()

    owner =
      Task.async(fn ->
        AgentPresence.present(agent)
        holder = Process.get({AgentPresence, agent.id})
        send(parent, {:holder, holder})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:holder, holder}, 5_000
    holder_ref = Process.monitor(holder)
    assert Presence.present?(agent.project_id, agent.id)

    send(owner.pid, :finish)
    assert Task.await(owner, 5_000) == :ok
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, :normal}, 5_000
  end
end
