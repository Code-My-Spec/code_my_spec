defmodule CodeMySpec.RunGuardTest do
  @moduledoc """
  Issue bee745a0: a test or spex run never outlives what started it. Real
  `sleep` processes stand in for `mix test`; the watch pattern is the only thing
  the tests change.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodeMySpec.RunGuard

  @watch ~r/sleep 31\d\d\d/

  setup do
    dir = Path.join(System.tmp_dir!(), "run_guard_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp start_guard(dir, opts \\ []) do
    name = :"guard_#{System.unique_integer([:positive])}"
    # Its own durable dir: this suite runs inside an analyzer's durable run,
    # whose manifest would otherwise protect every process spawned here.
    opts =
      Keyword.merge(
        [
          name: name,
          dir: dir,
          durable_dir: Path.join(dir, "durable"),
          watch: @watch,
          poll_ms: :infinity
        ],
        opts
      )

    {:ok, pid} = GenServer.start(RunGuard, opts, name: name)
    on_exit(fn -> stop_guard(pid) end)
    name
  end

  defp stop_guard(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # A process group of its own, as OTP gives every port spawn.
  defp run(seconds, command \\ nil) do
    parent = self()
    command = command || "sleep #{seconds}"

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            args: ["-c", command]
          ])

        {:os_pid, pid} = Port.info(port, :os_pid)
        send(parent, {:os_pid, pid})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:os_pid, pid}, 5_000
    {owner, pid}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, attempts - 1)
  end

  defp group_alive?(pid),
    do: match?({_, 0}, System.cmd("/bin/kill", ["-0", "--", "-#{pid}"], stderr_to_stdout: true))

  defp stop_group(pid),
    do: System.cmd("/bin/kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)

  test "a watched run is logged with its pid, and left alone while it has an owner", %{dir: dir} do
    guard = start_guard(dir)
    {owner, pid} = run(31_001)
    on_exit(fn -> stop_group(pid) end)

    capture_log(fn -> RunGuard.tick(guard) end)

    assert pid in RunGuard.tracked(guard)
    assert group_alive?(pid)
    assert File.exists?(Path.join([dir, System.pid(), Integer.to_string(pid)]))
    send(owner, :stop)
  end

  test "a run whose owner is gone is reaped", %{dir: dir} do
    guard = start_guard(dir)
    {owner, pid} = run(31_002)
    on_exit(fn -> stop_group(pid) end)
    RunGuard.tick(guard)

    Process.exit(owner, :kill)

    eventually(fn ->
      log = capture_log(fn -> RunGuard.tick(guard) end)
      assert log =~ "os_pid=#{pid} lost its owner" or pid not in RunGuard.tracked(guard)
    end)

    eventually(fn -> refute group_alive?(pid) end, 200)
    # The record goes once the guard has seen the group gone.
    eventually(fn ->
      RunGuard.tick(guard)
      refute File.exists?(Path.join([dir, System.pid(), Integer.to_string(pid)]))
    end)
  end

  test "a run over the ceiling is reaped whoever owns it", %{dir: dir} do
    guard = start_guard(dir, max_run_ms: 0)
    {_owner, pid} = run(31_003)
    on_exit(fn -> stop_group(pid) end)
    RunGuard.tick(guard)

    log = capture_log(fn -> RunGuard.tick(guard) end)

    assert log =~ "os_pid=#{pid} exceeded"

    eventually(
      fn ->
        RunGuard.tick(guard)
        refute group_alive?(pid)
        assert RunGuard.tracked(guard) == []
      end,
      200
    )
  end

  test "what a dead BEAM left is swept at boot, and a live BEAM's is not", %{dir: dir} do
    {_owner, pid} = run(31_004)
    on_exit(fn -> stop_group(pid) end)

    {out, 0} = System.cmd("/bin/ps", ["-o", "command=", "-p", Integer.to_string(pid)])
    dead = Path.join(dir, "999999")
    File.mkdir_p!(dead)
    File.write!(Path.join(dead, Integer.to_string(pid)), String.trim(out))

    live = Path.join(dir, System.pid() <> "0")
    File.mkdir_p!(live)

    capture_log(fn -> start_guard(dir) end)

    eventually(fn -> refute group_alive?(pid) end, 200)
    refute File.exists?(dead)
  end

  test "a run is tracked, with its record, until its group is confirmed gone", %{dir: dir} do
    guard = start_guard(dir, kill_grace_ms: 60_000)
    {owner, pid} = run(31_006, "trap '' TERM; exec sleep 31006")
    on_exit(fn -> stop_group(pid) end)
    RunGuard.tick(guard)
    Process.exit(owner, :kill)

    capture_log(fn ->
      eventually(fn ->
        RunGuard.tick(guard)
        assert group_alive?(pid)
        assert pid in RunGuard.tracked(guard)
      end)
    end)

    # TERM was ignored and the pause before KILL has not passed.
    assert File.exists?(Path.join([dir, System.pid(), Integer.to_string(pid)]))
  end

  test "a kill a restart interrupted is finished by the next guard", %{dir: dir} do
    guard = start_guard(dir, kill_grace_ms: 60_000)
    {owner, pid} = run(31_007, "trap '' TERM; exec sleep 31007")
    on_exit(fn -> stop_group(pid) end)
    RunGuard.tick(guard)
    Process.exit(owner, :kill)

    capture_log(fn ->
      eventually(fn ->
        RunGuard.tick(guard)
        assert File.exists?(Path.join([dir, System.pid(), Integer.to_string(pid)]))
        assert group_alive?(pid)
      end)
    end)

    # The harness dies after TERM and before KILL: no terminate, no cleanup.
    Process.exit(Process.whereis(guard), :kill)
    File.rename!(Path.join(dir, System.pid()), Path.join(dir, "999999"))
    assert group_alive?(pid)

    capture_log(fn -> start_guard(dir, kill_grace_ms: 100) end)

    eventually(fn -> refute group_alive?(pid) end, 200)
    refute File.exists?(Path.join(dir, "999999"))
  end

  test "an unrelated command is never tracked", %{dir: dir} do
    guard = start_guard(dir, watch: ~r/no such command/)
    {owner, pid} = run(31_005)
    on_exit(fn -> stop_group(pid) end)

    RunGuard.tick(guard)

    assert RunGuard.tracked(guard) == []
    assert group_alive?(pid)
    send(owner, :stop)
  end
end
