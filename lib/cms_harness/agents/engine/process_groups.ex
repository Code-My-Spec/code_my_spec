defmodule CmsHarness.Agents.Engine.ProcessGroups do
  @moduledoc false

  # OTP's Unix child launcher creates a session before exec. The port's
  # os_pid therefore identifies the owned group, even after reparenting.
  # Never infer ownership from a parent-child snapshot at cleanup time.
  def signal(groups, signal, deadline) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case command("/bin/kill", [signal, "--", "-#{group}"], deadline) do
        {:ok, _, status} when status in [0, 1] -> {:cont, :ok}
        error -> {:halt, {:error, {:group_signal_failed, group, error}}}
      end
    end)
  end

  def members([], _deadline), do: {:ok, []}

  def members(groups, deadline) do
    case command("/bin/ps", ["-axo", "pid=,pgid="], deadline) do
      {:ok, output, 0} ->
        pids =
          output
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line) do
              [pid, group] ->
                if String.to_integer(group) in groups, do: [String.to_integer(pid)], else: []

              _ ->
                []
            end
          end)

        {:ok, Enum.sort(pids)}

      error ->
        {:error, {:group_members_unavailable, groups, error}}
    end
  end

  def confirm(groups, deadline), do: confirm(groups, deadline, [])

  defp confirm(groups, deadline, last_observed) do
    if remaining(deadline) == 0 do
      {:error, {:subprocess_shutdown_unconfirmed, last_observed, {:groups, groups}}}
    else
      case members(groups, deadline) do
        {:ok, []} ->
          :ok

        {:ok, survivors} ->
          Process.sleep(min(20, remaining(deadline)))
          confirm(groups, deadline, survivors)

        error ->
          {:error, {:subprocess_shutdown_unconfirmed, last_observed, error}}
      end
    end
  end

  # Each utility has a deadline too: a stuck ps or kill must not consume
  # the server's entire outer cleanup window. Closing its port is bounded.
  defp command(executable, args, deadline) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    try do
      collect(port, [], min(deadline, System.monotonic_time(:millisecond) + 500))
    after
      close(port)
    end
  rescue
    exception -> {:error, {:utility_failed, Exception.message(exception)}}
  end

  defp collect(port, output, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect(port, [data | output], deadline)

      {^port, {:exit_status, status}} ->
        {:ok, output |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining(deadline) -> {:error, :utility_timeout}
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
