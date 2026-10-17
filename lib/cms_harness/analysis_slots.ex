defmodule CmsHarness.AnalysisSlots do
  @moduledoc """
  How many analyzer runs this machine will execute at once, across every working
  copy it serves.

  `Project.AnalysisServer` serializes runs within one copy; this bounds them
  across copies, because a saturated machine manufactures test failures rather
  than just running slowly. See knowledge/harness, "Analysis slots".

  A run that cannot get a slot waits, up to `wait_ceiling/0`, then answers
  `:busy`. `AnalysisServer` arms its kill timer only once a slot is granted.
  Named test files wait in their own `:fast` lane. A slot is released when the
  holding process exits; there is no `release/0`.
  """

  use GenServer

  require Logger

  # Same order as `AnalysisServer`'s kill timeout; past it, `:busy`.
  @wait_ceiling :timer.minutes(30)

  @doc """
  Take a slot, waiting for one to free if the machine is already at its
  limit. Answers `:busy` only if none frees within `wait_ceiling/0`.

  Call from the process that will do the work — the slot is held for that
  process's lifetime.
  """
  @spec acquire(lane()) :: :ok | :busy
  def acquire(lane \\ :full) when lane in [:full, :fast],
    do: GenServer.call(__MODULE__, {:acquire, lane}, wait_ceiling() + 5_000)

  @typedoc "`:fast` for runs of named test files, `:full` for everything else."
  @type lane :: :full | :fast

  @doc "The lane a run waits in: named test files are fast, a whole sweep is full."
  @spec lane(String.t(), [String.t()]) :: lane()
  def lane(source, [_ | _]) when source in ["exunit", "spex"], do: :fast
  def lane(_source, _args), do: :full

  @doc """
  How long `acquire/0` waits for a slot before giving up and answering
  `:busy`. Configurable as `:analysis_slot_wait_ceiling`.
  """
  @spec wait_ceiling() :: pos_integer()
  def wait_ceiling,
    do: Application.get_env(:code_my_spec, :analysis_slot_wait_ceiling, @wait_ceiling)

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
  def handle_call({:acquire, lane}, {pid, _tag} = from, state) do
    %{held: held, waiting: waiting} = state.lanes[lane]

    if map_size(held) >= limit(lane) do
      Logger.info(
        "[CmsHarness] an analyzer run is waiting for a machine-wide #{lane} slot: " <>
          "#{map_size(held)} already running (limit #{limit(lane)}), waiting up to " <>
          "#{wait_ceiling()}ms. held by: #{inspect(Map.values(held))}"
      )

      timer_ref = Process.send_after(self(), {:wait_timeout, lane, from}, wait_ceiling())
      {:noreply, put_lane(state, lane, :waiting, :queue.in({from, pid, timer_ref}, waiting))}
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

  # The waiter may already have been granted a slot (raced `maybe_grant_next/2`
  # between the timer firing and this message being processed) — in which case
  # it is no longer in `waiting` and there is nothing to time out.
  def handle_info({:wait_timeout, lane, from}, state) do
    case take_waiting(state.lanes[lane].waiting, from) do
      {:ok, waiting} ->
        GenServer.reply(from, :busy)
        {:noreply, put_lane(state, lane, :waiting, waiting)}

      :not_found ->
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
         {{:value, {from, pid, timer_ref}}, rest} <- :queue.out(waiting) do
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, :ok)
      state |> put_lane(lane, :waiting, rest) |> grant(lane, pid)
    else
      _ -> state
    end
  end

  defp take_waiting(waiting, target_from) do
    list = :queue.to_list(waiting)

    if Enum.any?(list, &match?({^target_from, _pid, _ref}, &1)) do
      {:ok, list |> Enum.reject(&match?({^target_from, _pid, _ref}, &1)) |> :queue.from_list()}
    else
      :not_found
    end
  end
end
