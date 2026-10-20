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
    opts = Keyword.merge([name: name, dir: dir, watch: @watch, poll_ms: :infinity], opts)
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
  defp run(seconds) do
    parent = self()

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, "/bin/sh"}, [
            :binary,
            :exit_status,
            args: ["-c", "sleep #{seconds}"]
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

  defp eventually(fun, attempts \\ 100) do
    fun.()
  rescue
    error in [ExUnit.AssertionError, MatchError] ->
      if attempts == 0 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(20)
        eventually(fun, attempts - 1)
      end
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
    refute File.exists?(Path.join([dir, System.pid(), Integer.to_string(pid)]))
  end

  test "a run over the ceiling is reaped whoever owns it", %{dir: dir} do
    guard = start_guard(dir, max_run_ms: 0)
    {_owner, pid} = run(31_003)
    on_exit(fn -> stop_group(pid) end)
    RunGuard.tick(guard)

    log = capture_log(fn -> RunGuard.tick(guard) end)

    assert log =~ "os_pid=#{pid} exceeded"
    eventually(fn -> refute group_alive?(pid) end, 200)
    assert RunGuard.tracked(guard) == []
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
