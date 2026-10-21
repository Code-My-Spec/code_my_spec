defmodule CmsHarness.Agents.Engine.Execution do
  @moduledoc false

  alias CmsHarness.Agents.Engine.ProcessGroups

  def stop(root), do: root |> capture() |> stop_owned()

  # For callers that hold no machine-wide slot (an agent's turn, its bash
  # tool): when termination of the OS groups cannot be confirmed, the BEAM
  # owners are released anyway, so a failed cleanup does not leave the turn's
  # processes suspended for good. The failure is still returned. Analysis keeps
  # `stop_owned/2`, whose owners hold capacity until their groups are gone.
  def stop_and_release(root, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    ownership = capture(root)

    case stop_owned(ownership, deadline) do
      :ok ->
        :ok

      {:error, _} = error ->
        release(ownership)
        error
    end
  end

  # Freeze BEAM owners before reading ports. OTP establishes a separate Unix
  # session/group at spawn, whose identity is the port's os_pid. Retain that
  # identity independently of the owners so overdue cleanup can still act
  # after their death and after OS descendants have been reparented.
  def capture(root) do
    suspend(root)
    children = Enum.filter(Process.list(), &descendant?(&1, root))
    Enum.each(children, &suspend/1)
    owners = [root | children]
    %{owners: owners, groups: owned_os_processes(owners)}
  end

  def stop_owned(ownership),
    do: stop_owned(ownership, System.monotonic_time(:millisecond) + 5_000)

  def stop_owned(ownership, deadline) do
    term_result = ProcessGroups.signal(ownership.groups, "-TERM", deadline)

    # Suspended owners retain their machine-wide slots until every owned OS
    # group is confirmed gone. Failed confirmation must not release capacity.
    Process.sleep(min(100, max(deadline - System.monotonic_time(:millisecond), 0)))
    kill_result = ProcessGroups.signal(ownership.groups, "-KILL", deadline)

    case ProcessGroups.confirm(ownership.groups, deadline) do
      :ok -> release(ownership)
      error -> {:error, {:cleanup_incomplete, error, term_result, kill_result}}
    end
  end

  def release(%{owners: owners}) do
    Enum.each(owners, &Process.exit(&1, :kill))
    :ok
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
end
