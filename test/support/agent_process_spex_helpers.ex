defmodule CodeMySpecSpex.AgentProcessHelpers do
  @moduledoc """
  A real process for story 1023's criteria to stop.

  The criteria are about whether an agent stops spending, so an agent that is
  not a process proves nothing about them. Three shipped instances of the same
  defect on this project all passed tests that never involved one.

  `sleep` is the agent. It is real, it spawns real children when asked, and it
  costs nothing — which matters, because the alternative is starting an actual
  coding agent and burning a subscription to assert a lifecycle rule.

  ## Why a helper rather than calling the runner from the spex

  `CodeMySpecSpex` may not reference `CmsHarness` — the boundary says so, and it
  is right: a spex reaching into the harness is a spex that has stopped driving
  the surface it is about. So the crossing happens once, here, where the other
  bridges live.
  """

  import ExUnit.Assertions

  alias CmsHarness.Agents.Runner

  @doc """
  Start something that behaves like an agent, and hand back what the server
  would have recorded for it.

  `:children` spawns extra processes inside the same group — the shape a real
  agent has when it is running a compiler or a test suite, and the shape
  `pkill -TERM -P` gets wrong by walking only one level.
  """
  @spec start_process(keyword()) :: %{os_pid: pos_integer(), os_boot_id: String.t()}
  def start_process(opts \\ []) do
    script =
      opts
      |> Keyword.get(:children, 0)
      |> body()
      |> trap(Keyword.get(opts, :traps_term, false))

    {:ok, %{pgid: pgid, boot_id: boot_id}} = Runner.start("/bin/sh", ["-c", script])

    ExUnit.Callbacks.on_exit(fn -> Runner.stop(%{pgid: pgid, boot_id: boot_id}, grace_ms: 0) end)

    %{os_pid: pgid, os_boot_id: boot_id}
  end

  defp body(0), do: "sleep 60"
  defp body(n), do: Enum.map_join(1..n, "", fn _ -> "sleep 60 & " end) <> "sleep 60"

  # An agent that will not go quietly. Not contrived: a wrapper with a swallowed
  # trap, a handler that deadlocks on the work it is trying to finish, or a
  # process blocked in a syscall all behave this way.
  defp trap(script, false), do: script
  defp trap(script, true), do: "trap '' TERM; " <> script

  defmodule UnreachableMachine do
    @moduledoc """
    A machine this server cannot reach.

    Not the same as a machine that says the agent is gone. The process is on a
    box we cannot currently talk to, so it is very likely still running and
    still spending — and the two want completely different things from whoever
    is reading.
    """
    @behaviour CodeMySpec.Agents.Transport

    @impl true
    def start_agent(_copy, _agent, _timeout), do: {:error, :harness_not_connected}

    @impl true
    def stop_agent(_copy, _agent, _timeout), do: {:error, :harness_not_connected}
  end

  @doc """
  Put the agent's machine out of reach for this scenario.

  Restored afterwards, because the transport is application-wide: leaving it
  swapped would make every later spex in the run talk to a machine that refuses
  everything, and they would fail for a reason that has nothing to do with them.
  """
  @spec machine_out_of_reach() :: :ok
  def machine_out_of_reach do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, UnreachableMachine)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :agent_transport, previous)
    end)

    :ok
  end

  @doc "Everything currently in this process group."
  @spec in_group(pos_integer()) :: [String.t()]
  def in_group(pgid) do
    {out, 0} = System.cmd("ps", ["-eo", "pid,pgid,command"])

    out
    |> String.split("\n")
    |> Enum.filter(fn line ->
      case String.split(String.trim(line), ~r/\s+/, parts: 3) do
        [_pid, group, _cmd] -> group == to_string(pgid)
        _ -> false
      end
    end)
  end

  @doc """
  Wait until the group holds at least `count` processes.

  Spawning is not instant, and counting before the children exist reads as a
  group that never had them.
  """
  @spec await_group(pos_integer(), pos_integer()) :: [String.t()]
  def await_group(pgid, count, attempts \\ 100)

  def await_group(pgid, count, 0),
    do: flunk("group #{pgid} never reached #{count} processes; got #{inspect(in_group(pgid))}")

  def await_group(pgid, count, attempts) do
    members = in_group(pgid)

    case length(members) >= count do
      true ->
        members

      false ->
        Process.sleep(10)
        await_group(pgid, count, attempts - 1)
    end
  end
end
