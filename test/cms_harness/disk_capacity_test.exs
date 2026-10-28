defmodule CmsHarness.DiskCapacityTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Engine.Server
  alias CmsHarness.DiskCapacity

  @mib 1024 * 1024

  test "checks checkout and temporary space, refusing the lower volume" do
    parent = self()

    reader = fn
      "/checkout" ->
        send(parent, {:checked, :checkout})
        {:ok, 1024 * @mib}

      "/tmp" ->
        send(parent, {:checked, :tmp})
        {:ok, 128 * @mib}
    end

    assert {:error, "disk nearly full: 128 MiB free"} =
             DiskCapacity.check(["/checkout", "/tmp"], reader)

    assert_received {:checked, :checkout}
    assert_received {:checked, :tmp}
  end

  test "admits exactly the minimum and refuses unreadable capacity" do
    assert :ok = DiskCapacity.check(["/checkout"], fn _ -> {:ok, 512 * @mib} end)

    assert {:error, reason} =
             DiskCapacity.check(["/checkout"], fn _ -> {:error, :unavailable} end)

    assert reason =~ "could not check disk space"
  end

  test "an agent turn is refused before consuming its message and reports why" do
    prior = Application.get_env(:code_my_spec, :harness_disk_capacity_reader)

    Application.put_env(:code_my_spec, :harness_disk_capacity_reader, fn _ ->
      {:ok, 64 * @mib}
    end)

    on_exit(fn ->
      if prior == nil,
        do: Application.delete_env(:code_my_spec, :harness_disk_capacity_reader),
        else: Application.put_env(:code_my_spec, :harness_disk_capacity_reader, prior)
    end)

    parent = self()

    state = %{
      turn: nil,
      working_copy: "/checkout",
      agent_id: "agent-1",
      on_event: fn id, event -> send(parent, {id, event}) end
    }

    assert {:reply, {:error, "disk nearly full: 64 MiB free"}, ^state} =
             Server.handle_call({:send, "ref", "work", 1000, false}, {self(), make_ref()}, state)

    assert_received {"agent-1",
                     %{event: :disk_capacity_refused, text: "disk nearly full: 64 MiB free"}}
  end
end
