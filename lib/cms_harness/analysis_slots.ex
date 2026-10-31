defmodule CmsHarness.AnalysisSlots do
  @moduledoc """
  How many analyzer runs this machine will execute at once, across every working
  copy it serves.

  `Project.AnalysisServer` serializes runs within one copy; this bounds them
  across copies, because a saturated machine manufactures test failures rather
  than just running slowly. See knowledge/harness, "Analysis slots".

  A run that cannot get a slot waits in line until one frees, gate runs first
  but never forever ahead of anyone; waiting is never a failure.
  `AnalysisServer` arms its kill timer only once a slot is granted.
  Named test files wait in their own `:fast` lane. A slot is released when the
  holding process exits; there is no `release/0`.
  """

  use GenServer

  require Logger

  # How many gate runs may go ahead of one waiting run: one promotion's
  # compiler, credo, exunit and spex.
  @max_overtaken 4

  @doc """
  Take a slot, waiting in line for one to free if the machine is already at
  its limit.

  Call from the process that will do the work — the slot is held for that
  process's lifetime.
  """
  @spec acquire(lane(), :gate | :normal) :: :ok
  def acquire(lane \\ :full, priority \\ :normal)
      when lane in [:full, :fast] and priority in [:gate, :normal],
      do: GenServer.call(__MODULE__, {:acquire, lane, priority}, :infinity)

  @typedoc "`:fast` for runs of named test files, `:full` for everything else."
  @type lane :: :full | :fast

  @doc "The lane a run waits in: named test files are fast, a whole sweep is full."
  @spec lane(String.t(), [String.t()]) :: lane()
  def lane(source, [_ | _]) when source in ["exunit", "spex"], do: :fast
  def lane(_source, _args), do: :full

  @doc """
  How many runs may execute at once on this machine.

  A quarter of the cores: each suite already runs `max_cases` at twice the
  scheduler count, so the limit counts suites. Configurable as
  `:analysis_slots` (full) and `:analysis_fast_slots` (fast).
  """
  @spec limit(lane()) :: pos_integer()
  def limit(lane \\ :full)

  def limit(:full) do
    Application.get_env(:code_my_spec, :analysis_slots) ||
      max(1, div(System.schedulers_online(), 4))
  end

  # As many as the full lane by default: a targeted run is a handful of files,
  # so the pair costs far less than two suites.
  def limit(:fast) do
    Application.get_env(:code_my_spec, :analysis_fast_slots) ||
      max(1, div(System.schedulers_online(), 4))
  end

  @doc "How many slots are in use right now. For diagnostics and tests."
  @spec in_use(lane()) :: non_neg_integer()
  def in_use(lane \\ :full), do: GenServer.call(__MODULE__, {:in_use, lane})

  @doc "How many callers are waiting for a slot right now. For diagnostics and tests."
  @spec waiting(lane()) :: non_neg_integer()
  def waiting(lane \\ :full), do: GenServer.call(__MODULE__, {:waiting, lane})

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok,
     %{
       lanes: %{
         full: %{held: %{}, waiting: :queue.new()},
         fast: %{held: %{}, waiting: :queue.new()}
       }
     }}
  end

  @impl true
  def handle_call({:acquire, lane, priority}, {pid, _tag} = from, state) do
    %{held: held, waiting: waiting} = state.lanes[lane]

    if map_size(held) >= limit(lane) do
      Logger.info(
        "[CmsHarness] an analyzer run is waiting for a machine-wide #{lane} slot: " <>
          "#{map_size(held)} already running (limit #{limit(lane)}), " <>
          "#{:queue.len(waiting)} ahead. held by: #{inspect(Map.values(held))}"
      )

      {:noreply, enqueue_waiter(state, lane, {from, pid, priority})}
    else
      Logger.info("[CmsHarness] #{inspect(pid)} granted a machine-wide #{lane} slot immediately")
      {:reply, :ok, grant(state, lane, pid)}
    end
  end

  def handle_call({:in_use, lane}, _from, state),
    do: {:reply, map_size(state.lanes[lane].held), state}

  def handle_call({:waiting, lane}, _from, state),
    do: {:reply, :queue.len(state.lanes[lane].waiting), state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.lanes, fn {_lane, %{held: held}} -> Map.has_key?(held, ref) end) do
      {lane, %{held: held}} ->
        Logger.info(
          "[CmsHarness] #{inspect(pid)} released its machine-wide #{lane} slot (#{inspect(reason)})"
        )

        {:noreply,
         state |> put_lane(lane, :held, Map.delete(held, ref)) |> maybe_grant_next(lane)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp put_lane(state, lane, key, value),
    do: %{state | lanes: Map.update!(state.lanes, lane, &Map.put(&1, key, value))}

  defp grant(state, lane, pid) do
    ref = Process.monitor(pid)
    put_lane(state, lane, :held, Map.put(state.lanes[lane].held, ref, pid))
  end

  defp maybe_grant_next(state, lane) do
    %{held: held, waiting: waiting} = state.lanes[lane]

    with true <- map_size(held) < limit(lane),
         {{:value, {from, pid, _priority}}, rest} <- :queue.out(waiting) do
      GenServer.reply(from, :ok)

      state
      |> put_lane(lane, :waiting, rest)
      |> put_lane(lane, :overtaken, Map.delete(overtaken(state, lane), pid))
      |> grant(lane, pid)
    else
      _ -> state
    end
  end

  # A gate run waits behind earlier gate runs and ahead of everything else:
  # every team's landing waits on the promotion gate. But only @max_overtaken
  # times per waiter: back-to-back promotions on a one-slot machine otherwise
  # starve an agent's run in line forever. A waiter that has been overtaken
  # enough holds its place, and the gate goes behind it.
  defp enqueue_waiter(state, lane, {_from, _pid, :gate} = waiter) do
    counts = overtaken(state, lane)

    # From the back: the gate passes every waiter it may, up to the first it
    # may not.
    {jumped, ahead} =
      state.lanes[lane].waiting
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.split_while(&overtakable?(&1, counts))

    counts =
      Enum.reduce(jumped, counts, fn {_from, pid, _priority}, counts ->
        Map.update(counts, pid, 1, &(&1 + 1))
      end)

    waiting = :queue.from_list(Enum.reverse(ahead, [waiter | Enum.reverse(jumped)]))
    state |> put_lane(lane, :waiting, waiting) |> put_lane(lane, :overtaken, counts)
  end

  defp enqueue_waiter(state, lane, waiter),
    do: put_lane(state, lane, :waiting, :queue.in(waiter, state.lanes[lane].waiting))

  defp overtakable?({_from, pid, priority}, counts),
    do: priority == :normal and Map.get(counts, pid, 0) < @max_overtaken

  # Counts sit beside the queue, not in its entries, so a hot reload of this
  # module finds the queue in the shape it expects; a lane from before the
  # reload has no counts yet.
  defp overtaken(state, lane), do: Map.get(state.lanes[lane], :overtaken, %{})
end
