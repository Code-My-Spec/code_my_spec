defmodule CmsHarness.SyncMachineLoadTest do
  @moduledoc """
  The producer half of story 1057 / criterion 3324.

  `Machinery.saturated?/2` and the report it feeds have been readable since
  the story landed; nothing ever sent `machine_load` to make them fire. Drives
  `CmsHarness.Sync.measure_machine_load/1` — the real public entry point,
  called on its own timer independent of any scan — the same way
  `CmsHarness.SyncGitStateTest` drives `measure_checkout/1`: a fake channel
  registered where `CmsHarness.Project.ChannelClient.deliver_machine_load/2`
  looks one up by root, standing in for the real one.

  `sysctl`/`vm_stat` are recorded rather than run live: this box's own load
  and free memory change on every run, and the point of this test is that the
  parsing is right, not what this box happened to be carrying when the suite
  ran. `record: :none` so a cassette miss errors loudly instead of quietly
  recording this box's live (and non-deterministic) numbers over it.
  """
  use ExUnit.Case, async: false
  use ExCliVcr

  alias CmsHarness.Sync

  setup do
    CmsHarnessTest.Machine.ensure_supervisor()
    :ok
  end

  # A stand-in for `CmsHarness.Project.ChannelClient`, registered where the
  # real one registers. `deliver_machine_load/2` looks a channel up by root
  # and casts to it, so anything registered under that key is a channel as
  # far as it knows — same pattern `CmsHarness.SyncGitStateTest`'s
  # `fake_channel/1` uses.
  defp fake_channel(root) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)

        receive do
          {:"$gen_cast", {:machine_load, load}} -> send(test, {:machine_load, load})
        after
          5_000 -> :ok
        end
      end)

    wait_for_registration(root)
    pid
  end

  defp wait_for_registration(root, attempts \\ 100)

  defp wait_for_registration(_root, 0), do: flunk("no channel ever registered")

  defp wait_for_registration(root, attempts) do
    CmsHarness.Registry
    |> Registry.lookup({:channel, root})
    |> registration_result(root, attempts)
  end

  defp registration_result([_], _root, _attempts), do: :ok

  defp registration_result([], root, attempts) do
    Process.sleep(5)
    wait_for_registration(root, attempts - 1)
  end

  test "a recorded macOS reading is reported as load average, cpu count and free memory" do
    root = "spex-machine-load-#{System.unique_integer([:positive])}"
    fake_channel(root)

    use_cmd_cassette "sync_machine_load_darwin", record: :none do
      Sync.measure_machine_load(root)
    end

    assert_receive {:machine_load, load}, 5_000

    # `sysctl -n vm.loadavg` => "{ 31.40 25.10 20.05 }" -- the one-minute
    # figure is the first of the three.
    assert load["load_average"] == 31.4

    # `vm_stat`'s "Pages free: 10000." + "Pages speculative: 1520." at a
    # 16384-byte page size is exactly 180MB -- chosen so the arithmetic is
    # checkable by hand, not because it is a realistic reading.
    assert load["memory_free_mb"] == 180

    # Not recorded: this machine's own count, the same figure
    # `Machinery.saturated?/2` compares `load_average` against.
    assert load["cpu_count"] == :erlang.system_info(:logical_processors_available)
  end
end
