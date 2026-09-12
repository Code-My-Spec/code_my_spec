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

  ## Refuses rather than queues, and that is the design

  A run that cannot get a slot is answered `:busy` at once. It does **not** wait
  in line.

  Queueing was the obvious shape and it is wrong here. `AnalysisServer` arms a
  thirty-minute kill timer when it dispatches, before the run reaches this — so
  a run that waited behind four others would burn its budget waiting and be
  killed for being slow. Worse, it would be killed *as though the tool hung*,
  which is the exact misattribution this module exists to stop.

  `:busy` costs nothing: the stop hook re-enqueues what is stale, so a refused
  run is retried on the next stop, by which time the machine may be free. And it
  keeps the rule `AnalysisServer` states in its own moduledoc — "every request
  is answered; silence is the one answer this must never give."

  ## Released by death, not by discipline

  The caller is monitored and the slot comes back when it exits. There is no
  `release/0` to forget and none to call twice, and a run killed by the
  thirty-minute timeout frees its slot on the way out like any other exit. A
  semaphore that leaks stops analysis on the whole machine, which is worse than
  the saturation it was added to fix.
  """

  use GenServer

  require Logger

  @doc """
  Take a slot, or `:busy` if the machine is already running its limit.

  Call from the process that will do the work — the slot is held for that
  process's lifetime.
  """
  @spec acquire() :: :ok | :busy
  def acquire, do: GenServer.call(__MODULE__, :acquire)

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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{held: %{}}}

  @impl true
  def handle_call(:acquire, {pid, _tag}, %{held: held} = state) do
    if map_size(held) >= limit() do
      Logger.info(
        "[CmsHarness] refusing an analyzer run: #{map_size(held)} already running on this " <>
          "machine (limit #{limit()}). It will be re-enqueued by the next stop."
      )

      {:reply, :busy, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | held: Map.put(held, ref, pid)}}
    end
  end

  def handle_call(:in_use, _from, state), do: {:reply, map_size(state.held), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{held: held} = state) do
    {:noreply, %{state | held: Map.delete(held, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
