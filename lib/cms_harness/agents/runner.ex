defmodule CmsHarness.Agents.Runner do
  @moduledoc """
  Starts an agent in its own process group, and ends it by signalling that group.

  The missing producer. `Agents.start_agent/2` on the server mints a config
  directory, creates a row at `:starting` and opens a conversation — and
  launches nothing. `Agents.record_started/3` exists to record the pid a device
  reports back and had **no callers anywhere**. This is what makes that call.

  ## Why a process group

  So that what the agent spawned goes with the agent. An agent runs tools —
  compilers, test suites, `git` — and killing only the process we launched
  leaves those behind holding the working copy open and, if they are the thing
  burning tokens, still burning them.

  `Workspaces.Runner.Local` reaps with `pkill -TERM -P` then `kill -TERM`, and
  its own comment concedes it does "not walk past one level of children". A
  group is the whole tree in one signal, with no walking.

  ## The Darwin problem, and what was measured

  macOS ships no `setsid`. `Workspaces.Runner.Local` hits this and falls back to
  merely disowning the child — which is exactly why its moduledoc says a
  supervisor-tree restart can orphan the process while the row still points at
  it. That is story 961's criterion 2828, in shipped code, caused by the
  platform gap rather than by the design.

  `/usr/bin/perl -e 'setpgrp; exec @ARGV'` is the substitute and it is present
  on macOS by default. Measured here rather than assumed, which is the check
  story 956's notes flagged for MuonTrap and nobody had run:

      group 35032, before:
        35032 35032 /bin/sh -c sleep 90 & sleep 90
        35034 35032 sleep 90
        35035 35032 sleep 90
      kill -TERM -35032
      after: nothing left in the group

  `exec` matters: perl replaces itself with the agent, so the group leader *is*
  the agent and there is no wrapper process left to account for.

  ## Why the pid is also the group id

  `setpgrp` with no arguments makes the caller a group leader, so its pid and
  its group id are the same number. The shell's `$!` is that pid, which is why
  starting can report the group id without the wrapper having to communicate
  anything back.

  ## Detached on purpose

  The agent outlives the harness. That is not an accident to be designed out —
  a harness restart (`just refresh-harness` is routine here) must not kill
  everybody's agents, and an agent that survives one is exactly the orphan
  `stop/2` and the reaper have to be able to find afterwards.

  ## Why a boot id is recorded beside the group id

  Group ids are reused. A number recorded before a reboot can name an unrelated
  process afterwards, and a reaper acting on it would signal a stranger — the
  worst available failure, since it is somebody else's process and we would
  never know. So liveness is "the boot is the same *and* the group exists",
  and a handle from a previous boot answers dead without signalling anything.
  """

  require Logger

  @term_grace_ms 5_000

  @type handle :: %{pgid: pos_integer(), boot_id: String.t()}

  @doc """
  Start `command` with `args` in a new process group.

  `:cd` sets the working directory, `:env` the environment, `:log` a file to
  send output to. Returns the handle `stop/2` and `alive?/1` take.
  """
  @spec start(String.t(), [String.t()], keyword()) :: {:ok, handle()} | {:error, term()}
  def start(command, args, opts \\ []) do
    with {:ok, group_leader} <- group_leader_wrapper(),
         {:ok, pgid} <- spawn_detached(group_leader, command, args, opts) do
      {:ok, %{pgid: pgid, boot_id: boot_id()}}
    end
  end

  @doc """
  End everything in the group: TERM, then KILL if it is still there.

  The grace period is what lets an agent finish the commit it was making. It is
  bounded because the alternative is a stop the operator asked for that waits
  while the meter runs — which is the failure the story is about.

  Answers `:ok` when the group is gone and `{:error, :still_running}` when it
  survived both signals. Never reports success it has not checked: a stop that
  says done over a process that is still spending is the one outcome worse than
  a stop that failed.
  """
  @spec stop(handle(), keyword()) :: :ok | {:error, :still_running}
  def stop(handle, opts \\ []) do
    grace = Keyword.get(opts, :grace_ms, @term_grace_ms)

    handle
    |> knowable()
    |> do_stop(handle, grace)
  end

  # A group id with no boot beside it cannot be judged, and both available
  # answers are wrong: signalling it may TERM a stranger's process, and
  # reporting `:ok` says a stop happened over something that may still be
  # running and spending. So it says neither.
  #
  # Reachable whenever something records `os_pid` without `os_boot_id`. The two
  # are written together by `record_started/3` precisely so this stays
  # unreachable — and a silent `:ok` is what would hide it if that ever stopped
  # being true.
  defp knowable(%{pgid: pgid, boot_id: boot_id}) when is_integer(pgid) and is_binary(boot_id),
    do: alive?(%{pgid: pgid, boot_id: boot_id})

  defp knowable(_handle), do: :unknowable

  # Nothing of ours is running, so there is nothing to stop and nothing to
  # report as failed. That covers an agent already gone *and* a handle from a
  # previous boot, which are the same statement: our agent is not running.
  #
  # It must not answer `still_running` for the stale case. A caller that gets
  # that retries and escalates, and escalating against a recycled group id means
  # KILLing a stranger's process — with our own boot check standing between the
  # two and being overruled by a report it did not make.
  defp do_stop(:unknowable, handle, _grace) do
    Logger.warning(
      "[CmsHarness] refusing to stop #{inspect(handle)}: a process group id without the " <>
        "boot it belongs to cannot be told from a recycled number. Nothing was signalled " <>
        "and nothing is being reported as stopped."
    )

    {:error, :no_boot_id}
  end

  defp do_stop(false, _handle, _grace), do: :ok

  defp do_stop(true, handle, grace) do
    signal(handle, "TERM")

    handle
    |> wait_for_exit(grace)
    |> insist(handle)
  end

  defp insist(:ok, _handle), do: :ok

  defp insist(:still_running, handle) do
    signal(handle, "KILL")
    # A short window, because KILL is not refusable — this is waiting for the
    # kernel to finish, not for the process to cooperate.
    case wait_for_exit(handle, 1_000) do
      :ok -> :ok
      :still_running -> {:error, :still_running}
    end
  end

  @doc """
  Is anything still running in this group, and is it still ours?

  Both halves matter. The group existing is not enough — group ids are reused
  across boots, so a handle minted before the last reboot can name a live
  process belonging to somebody else.
  """
  @spec alive?(handle()) :: boolean()
  def alive?(%{boot_id: boot_id} = handle) when is_binary(boot_id) do
    boot_id == boot_id() and group_exists?(handle)
  end

  def alive?(_handle), do: false

  # Signal 0 asks whether a group exists without touching it. The negative pid
  # is what makes it the *group* rather than one process.
  defp group_exists?(%{pgid: pgid}) do
    {_out, status} = System.cmd("kill", ["-0", "-#{pgid}"], stderr_to_stdout: true)
    status == 0
  end

  defp signal(%{pgid: pgid} = handle, name) do
    case alive?(handle) do
      # Refusing rather than signalling is the whole point of the boot check:
      # a stale group id names somebody else's process, and TERMing it is a
      # failure nobody would ever trace back to here.
      false ->
        :ok

      true ->
        System.cmd("kill", ["-#{name}", "-#{pgid}"], stderr_to_stdout: true)
        :ok
    end
  end

  # `alive?/1` throughout, not `group_exists?/1`. One definition of running, or
  # the boot check guards the signal and not the verdict — which is exactly the
  # split that made stopping a stale handle refuse to signal and then report it
  # had failed to stop.
  defp wait_for_exit(handle, remaining_ms) when remaining_ms <= 0 do
    case alive?(handle) do
      true -> :still_running
      false -> :ok
    end
  end

  defp wait_for_exit(handle, remaining_ms) do
    case alive?(handle) do
      false -> :ok
      true -> poll_again(handle, remaining_ms)
    end
  end

  defp poll_again(handle, remaining_ms) do
    step = min(100, remaining_ms)
    Process.sleep(step)
    wait_for_exit(handle, remaining_ms - step)
  end

  # `$!` is the backgrounded wrapper's pid, and `setpgrp` made that pid a group
  # leader, so it is also the group id. Reported by the shell rather than by the
  # wrapper, because the wrapper `exec`s and has no chance to say anything after
  # it becomes the agent.
  defp spawn_detached(group_leader, command, args, opts) do
    log = Keyword.get(opts, :log, "/dev/null")

    script =
      (group_leader ++ [command | args])
      |> Enum.map_join(" ", &shell_quote/1)
      |> then(&"#{&1} > #{shell_quote(log)} 2>&1 & echo $!")

    case System.cmd("sh", ["-c", script], cmd_opts(opts)) do
      {out, 0} -> parse_pgid(out)
      {out, status} -> {:error, {:spawn_failed, status, String.trim(out)}}
    end
  end

  defp cmd_opts(opts) do
    [stderr_to_stdout: true]
    |> put_opt(:cd, Keyword.get(opts, :cd))
    |> put_opt(:env, Keyword.get(opts, :env))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_pgid(out) do
    case out |> String.trim() |> Integer.parse() do
      {pgid, _rest} when pgid > 0 -> {:ok, pgid}
      _ -> {:error, {:no_pgid, String.trim(out)}}
    end
  end

  # `setsid` where it exists, perl where it does not. Both end in `exec`, so the
  # agent replaces the wrapper and the group leader is the agent itself.
  #
  # A list of argv parts rather than one string: each is quoted separately when
  # the script is built, and a wrapper returned as a single string gets quoted
  # as one argument — the shell then looks for a file whose name is the entire
  # command line.
  defp group_leader_wrapper do
    case System.find_executable("setsid") do
      nil -> perl_wrapper()
      setsid -> {:ok, [setsid]}
    end
  end

  defp perl_wrapper do
    case System.find_executable("perl") do
      nil -> {:error, :no_way_to_make_a_process_group}
      perl -> {:ok, [perl, "-e", "setpgrp; exec @ARGV", "--"]}
    end
  end

  @doc """
  A string that changes when the machine reboots.

  Used to tell a live group id from a recycled one. Read fresh rather than
  cached: a cached value would survive a reboot inside a long-lived process and
  defeat the check it exists for.
  """
  @spec boot_id() :: String.t()
  def boot_id do
    case :os.type() do
      {:unix, :darwin} -> darwin_boot_id()
      {:unix, _} -> read_boot_id("cat", ["/proc/sys/kernel/random/boot_id"])
      _ -> "unknown"
    end
  end

  # Darwin has no `boot_id` file; `kern.boottime` is the substitute, and only
  # its `sec` field may be kept.
  #
  # The whole line is `{ sec = 1785496564, usec = 600843 } Fri Jul 31 07:16:04
  # 2026`, and storing it whole — which is what this did — makes the token
  # depend on `usec` and on a formatted date. Darwin derives boottime from the
  # current clock rather than recording it, so any clock step moves those. A
  # moved token makes `alive?/1` say a live agent is dead, and `stop/2` then
  # declines to signal a group that is still running: an agent nobody can stop,
  # still spending, which is the one failure this whole story exists to prevent.
  #
  # `sec` alone survives that. It is what identifies the boot; the rest is
  # precision this comparison cannot use and jitter it cannot absorb.
  defp darwin_boot_id do
    case read_boot_id("sysctl", ["-n", "kern.boottime"]) do
      "unknown" -> "unknown"
      line -> boot_seconds(line)
    end
  end

  defp boot_seconds(line) do
    case Regex.run(~r/sec\s*=\s*(\d+)/, line) do
      [_, seconds] -> seconds
      # A Darwin that words it differently keeps the whole line: still stable
      # within a boot, still changes across one. Only the jitter is lost.
      nil -> line
    end
  end

  # A machine that will not say when it booted gets a constant, which makes the
  # boot check a no-op rather than making every handle read dead — failing the
  # other way would make `stop/2` refuse to signal anything at all.
  #
  # `System.cmd/3` raises when the executable is missing, so the executable is
  # looked up first. Rescuing instead would also swallow a real failure in the
  # command itself and report it as the same "unknown".
  defp read_boot_id(command, args) do
    case System.find_executable(command) do
      nil -> "unknown"
      path -> run_boot_id(path, args)
    end
  end

  defp run_boot_id(path, args) do
    case System.cmd(path, args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  end

  # Single-quote everything and escape embedded quotes the POSIX way: close,
  # escaped quote, reopen. Unconditional, because deciding per-argument which
  # strings are "safe" is how a path with a space in it becomes two arguments —
  # and the agent's command line is whatever the caller passes.
  defp shell_quote(part) do
    "'" <> String.replace(part, "'", "'\\''") <> "'"
  end
end
