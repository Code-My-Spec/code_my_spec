defmodule CmsHarness.AnalysisSlots do
  @moduledoc """
  How many analyzer runs this machine will execute at once, across every working
  copy it serves.

  ## The gap this closes

  `Project.AnalysisServer` serializes runs within one working copy, for a good
  reason it states: `mix test` and `mix spex` share `_build/test`, and two at
  once corrupt the build. Nothing serializes *across* copies, and one harness
  serves every checkout on the machine — eleven of them here.

  So each agent behaves correctly and the machine does not. An agent that wants
  to promote needs a fresh sweep, so it starts one; six agents wanting to
  promote start six full `mix test` + `mix spex` runs against one box, plus the
  dev server, plus the harness, plus their own `_build` compiles.

  Measured 2026-09-12 (`3e9b7568`): load 54 on ten cores, eight concurrent
  suites, two running over twenty minutes. And again later the same day at load
  17–21 with three.

  ## The failure is not slowness

  Under that load the analyzer **manufactures failures**. Whichever test is
  heaviest dies with `** (EXIT from #PID<…>)` and passes in isolation, and the
  victim moves between sweeps — `exunit reconciled: 1 problem — 1 gone, 1 new`.

  Three separate promotions were refused that way in one session, each naming a
  different innocent test: `criterion_2848`, an ordering test in
  `agent_conversation_live`, then `criterion_2833`. Every one green in
  isolation, twenty consecutive runs apiece.

  A slow sweep costs time. A sweep that invents a different failure each run
  costs *confidence*, and the natural response to a phantom — retry — is what
  produces the next one.

  ## Waits rather than refusing, now — the timer moved instead

  A run that cannot get a slot waits for one, up to a generous ceiling
  (`wait_ceiling/0`, the same order of magnitude as an analyzer's own
  thirty-minute kill timeout). It used to be answered `:busy` at once, on the
  reasoning that `AnalysisServer` arms its kill timer at dispatch — before the
  run reaches here — so a run that waited behind four others would burn its
  budget waiting and be killed for being slow, misattributed as a hung tool.

  That reasoning was right about the misattribution and wrong about the fix.
  The kill timer has moved instead: `AnalysisServer` now arms it only once
  `acquire/0` actually returns `:ok` (story 839, criterion 3440), so waiting
  here costs nothing from that budget — the clock does not start until the
  analyzer is actually running. Refusing instantly was curing the symptom;
  the actual disease was where the timer started.

  Past the ceiling, `acquire/0` still answers `:busy` rather than waiting
  forever — the same reason `AnalysisServer`'s own moduledoc gives: "every
  request is answered; silence is the one answer this must never give." A
  machine still saturated after thirty-odd minutes has a real problem this
  module cannot solve by waiting longer, and the stop hook re-enqueues what is
  stale on the next pass regardless.

  ## Released by death, not by discipline

  The caller is monitored and the slot comes back when it exits. There is no
  `release/0` to forget and none to call twice, and a run killed by the
  thirty-minute timeout frees its slot on the way out like any other exit. A
  semaphore that leaks stops analysis on the whole machine, which is worse than
  the saturation it was added to fix.
  """

  use GenServer

  require Logger

  # Same order of magnitude as `AnalysisServer`'s own kill timeout — long
  # enough that a genuinely busy machine gets a real chance to drain, short
  # enough that a caller is never left believing this waits forever. Past it,
  # `acquire/0` still answers, just with `:busy` instead of `:ok`.
  @wait_ceiling :timer.minutes(30)

  @doc """
  Take a slot, waiting for one to free if the machine is already at its
  limit. Answers `:busy` only if none frees within `wait_ceiling/0`.

  Call from the process that will do the work — the slot is held for that
  process's lifetime.
  """
  @spec acquire() :: :ok | :busy
  def acquire, do: GenServer.call(__MODULE__, :acquire, wait_ceiling() + 5_000)

  @doc """
  How long `acquire/0` waits for a slot before giving up and answering
  `:busy`. Configurable as `:analysis_slot_wait_ceiling` for the same reason
  `:analysis_slots` is — a test, or a machine whose analyzers run far longer
  or shorter than thirty minutes.
  """
  @spec wait_ceiling() :: pos_integer()
  def wait_ceiling,
    do: Application.get_env(:code_my_spec, :analysis_slot_wait_ceiling, @wait_ceiling)

  @doc """
  How many runs may execute at once on this machine.

  A fraction of the cores rather than a count of projects, because the projects
  are what is unbounded. Each `mix test` sets `max_cases` to twice the scheduler
  count on its own, so two suites already oversubscribe a ten-core box — the
  limit is about how many *suites*, not how many processes.

  Configurable as `:analysis_slots` for a machine that is only running one
  thing, or a much larger one.
  """
  @spec limit() :: pos_integer()
  def limit do
    Application.get_env(:code_my_spec, :analysis_slots) ||
      max(1, div(System.schedulers_online(), 4))
  end

  @doc "How many slots are in use right now. For diagnostics and tests."
  @spec in_use() :: non_neg_integer()
  def in_use, do: GenServer.call(__MODULE__, :in_use)

  @doc "How many callers are waiting for a slot right now. For diagnostics and tests."
  @spec waiting() :: non_neg_integer()
  def waiting, do: GenServer.call(__MODULE__, :waiting)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{held: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, %{held: held} = state) do
    if map_size(held) >= limit() do
      Logger.info(
        "[CmsHarness] an analyzer run is waiting for a machine-wide slot: " <>
          "#{map_size(held)} already running (limit #{limit()}), waiting up to " <>
          "#{wait_ceiling()}ms."
      )

      timer_ref = Process.send_after(self(), {:wait_timeout, from}, wait_ceiling())
      {:noreply, %{state | waiting: :queue.in({from, pid, timer_ref}, state.waiting)}}
    else
      {:reply, :ok, grant(state, pid)}
    end
  end

  def handle_call(:in_use, _from, state), do: {:reply, map_size(state.held), state}
  def handle_call(:waiting, _from, state), do: {:reply, :queue.len(state.waiting), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{held: held} = state) do
    state = %{state | held: Map.delete(held, ref)}
    {:noreply, maybe_grant_next(state)}
  end

  # The waiter may already have been granted a slot (raced `maybe_grant_next/1`
  # between the timer firing and this message being processed) — in which case
  # it is no longer in `waiting` and there is nothing to time out.
  def handle_info({:wait_timeout, from}, state) do
    case take_waiting(state.waiting, from) do
      {:ok, waiting} ->
        GenServer.reply(from, :busy)
        {:noreply, %{state | waiting: waiting}}

      :not_found ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp grant(state, pid) do
    ref = Process.monitor(pid)
    %{state | held: Map.put(state.held, ref, pid)}
  end

  defp maybe_grant_next(%{held: held, waiting: waiting} = state) do
    with true <- map_size(held) < limit(),
         {{:value, {from, pid, timer_ref}}, rest} <- :queue.out(waiting) do
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, :ok)
      grant(%{state | waiting: rest}, pid)
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
