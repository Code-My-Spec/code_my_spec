defmodule CodeMySpec.CodeMode.Progress do
  @moduledoc """
  What a script had done when it was stopped.

  A timed-out script is killed, and its process dictionary — prints included —
  dies with it. So each tool call and print is also sent to the process waiting
  on the script, which can then say which call was still waiting and for how
  long, instead of only that something took too long (7fe2d0fa).
  """

  @key {__MODULE__, :listener}

  @doc "Called inside the script's task: report progress to `listener`."
  @spec listen(pid(), reference()) :: :ok
  def listen(listener, tag) do
    Process.put(@key, {listener, tag})
    :ok
  end

  @doc "Reports one event, if anyone is listening."
  @spec report(term()) :: :ok
  def report(event) do
    case Process.get(@key) do
      {listener, tag} -> send(listener, {tag, event, now()})
      nil -> :ok
    end

    :ok
  end

  @doc "Takes every reported event for `tag` from the mailbox, oldest first."
  @spec collect(reference()) :: [{term(), integer()}]
  def collect(tag), do: collect(tag, [])

  defp collect(tag, acc) do
    receive do
      {^tag, event, at} -> collect(tag, [{event, at} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  The sentence a timeout reports: the call still waiting, what finished, and
  what the script printed.
  """
  @spec describe([{term(), integer()}], integer()) :: String.t()
  def describe(events, stopped_at) do
    {done, pending} = replay(events)

    Enum.join(
      Enum.reject(
        [in_flight(pending, stopped_at), finished(done), printed(events)],
        &is_nil/1
      ),
      "\n"
    )
  end

  @spec now() :: integer()
  def now, do: System.monotonic_time(:millisecond)

  # Calls run one at a time, so the open call is the last one started and not
  # yet finished.
  defp replay(events) do
    Enum.reduce(events, {[], nil}, fn
      {{:call, name}, at}, {done, _pending} -> {done, {name, at}}
      {{:done, name}, at}, {done, {name, started}} -> {[{name, at - started} | done], nil}
      _other, acc -> acc
    end)
    |> then(fn {done, pending} -> {Enum.reverse(done), pending} end)
  end

  defp in_flight(nil, _stopped_at),
    do: "No tool call was in flight: the deadline fell inside the script's own code."

  defp in_flight({name, started}, stopped_at),
    do: "Still waiting on `#{name}`, called #{stopped_at - started}ms before the deadline."

  defp finished([]), do: "No call had finished."

  defp finished(done) do
    "Finished before it: " <> Enum.map_join(done, ", ", fn {name, ms} -> "#{name} (#{ms}ms)" end)
  end

  defp printed(events) do
    case for({{:print, line}, _at} <- events, do: line) do
      [] -> nil
      lines -> "Printed:\n" <> Enum.join(lines, "\n")
    end
  end
end
