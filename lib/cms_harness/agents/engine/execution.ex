defmodule CmsHarness.Agents.Engine.Execution do
  @moduledoc false

  # Called only when execution must be aborted. Freeze its BEAM owners before
  # discovering ports, so they cannot launch another subprocess during cleanup.
  def stop(root) do
    suspend(root)

    children = Enum.filter(Process.list(), &descendant?(&1, root))
    Enum.each(children, &suspend/1)
    owners = [root | children]
    os_roots = owned_os_processes(owners)

    case process_tree(os_roots) do
      {:ok, os_processes} ->
        Enum.each(os_processes, &signal_kill/1)
        monitors = Enum.map(owners, &{&1, Process.monitor(&1)})
        Enum.each(owners, &Process.exit(&1, :kill))
        deadline = System.monotonic_time(:millisecond) + 5_000

        with :ok <- await_owners(monitors, deadline) do
          await_subprocesses(os_processes, deadline)
        end

      error ->
        Enum.each(owners, &Process.exit(&1, :kill))
        error
    end
  end

  defp suspend(pid) do
    :erlang.suspend_process(pid)
  rescue
    ArgumentError -> :ok
  end

  defp descendant?(pid, root) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        root in Keyword.get(dictionary, :"$ancestors", []) or
          root in Keyword.get(dictionary, :"$callers", [])

      nil ->
        false
    end
  end

  defp owned_os_processes(owners) do
    for port <- Port.list(),
        {:connected, owner} <- [Port.info(port, :connected)],
        owner in owners,
        {:os_pid, pid} <- [Port.info(port, :os_pid)],
        is_integer(pid) and pid > 1,
        do: pid
  end

  defp process_tree([]), do: {:ok, []}

  defp process_tree(roots) do
    case System.cmd("ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        edges =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [pid, parent] = String.split(line)
            {String.to_integer(pid), String.to_integer(parent)}
          end)

        {:ok, descendants(MapSet.new(roots), edges) |> MapSet.to_list()}

      {_output, status} ->
        {:error, {:process_tree_unavailable, status}}
    end
  end

  defp descendants(known, edges) do
    expanded =
      Enum.reduce(edges, known, fn {pid, parent}, acc ->
        if MapSet.member?(known, parent), do: MapSet.put(acc, pid), else: acc
      end)

    if MapSet.equal?(known, expanded), do: known, else: descendants(expanded, edges)
  end

  defp signal_kill(pid) do
    System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp await_owners([], _deadline), do: :ok

  defp await_owners([{pid, ref} | rest], deadline) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> await_owners(rest, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Enum.each([{pid, ref} | rest], fn {_pid, monitor} ->
          Process.demonitor(monitor, [:flush])
        end)

        {:error, :execution_shutdown_unconfirmed}
    end
  end

  defp await_subprocesses([], _deadline), do: :ok

  defp await_subprocesses(pids, deadline) do
    remaining =
      Enum.filter(pids, fn pid ->
        {_output, status} =
          System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

        status == 0
      end)

    cond do
      remaining == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:subprocess_shutdown_unconfirmed, remaining}}

      true ->
        Process.sleep(10)
        await_subprocesses(remaining, deadline)
    end
  end
end
