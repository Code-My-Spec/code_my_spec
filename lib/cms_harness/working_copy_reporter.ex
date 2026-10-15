defmodule CmsHarness.WorkingCopyReporter do
  @moduledoc """
  Keeps saying which of this machine's checkouts are still on disk.

  `CmsHarness.Device.announce/1` carries the observation; this is what computes
  it and what makes it happen more than once.

  It remembers every copy it has known (`known`): a removed worktree takes its
  `.cms_harness.json` with it and stops naming itself, so removal is inferred
  from the directory going away. After a restart the harness has served
  nothing yet, so the server's answer (the copies attached to this device) is
  merged into `known`, and those copies are served.

  On a timer, because removing a worktree emits no event to wait for. It
  reports and never decides: the server raises a warning and clears it if the
  path returns; offboarding is a person's act.
  See knowledge/harness, "Working-copy reporting".
  """

  use GenServer

  require Logger

  alias CmsHarness.Device
  alias CmsHarness.Projects
  alias CmsHarness.Projects.Generator
  alias CmsHarness.ServedRoots

  # A checkout is removed rarely and nothing acts on the news automatically.
  @heartbeat :timer.minutes(2)

  # Start the authoritative roster exchange as soon as the supervision tree
  # exists. Credentials can bootstrap from durable served-root hints without
  # first starting channels, so an offline offboard stays offboarded.
  @first_report 0

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: name(opts))

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)

  @doc """
  Report now and wait for it, rather than on the next tick.

  A call, so the caller knows the report was made. Returns what it told the
  server.
  """
  @spec report(GenServer.server()) :: %{optional(String.t()) => boolean()}
  def report(server \\ __MODULE__), do: GenServer.call(server, :report, 30_000)

  @impl GenServer
  def init(opts) do
    # `:never` leaves every report to the caller; `heartbeat: :never` stops the
    # ticking too.
    case Keyword.get(opts, :first_report, @first_report) do
      :never -> :ok
      delay -> schedule(delay)
    end

    # `known`: copies served and where (seedable, restorable state).
    # `last`: the previous report, so a repeat is not logged twice.
    # `generating`: pending projects with a generation task in flight, so a slow
    # generation is not launched twice.
    {:ok,
     %{
       known: Keyword.get(opts, :known, %{}),
       last: nil,
       generating: MapSet.new(),
       heartbeat: Keyword.get(opts, :heartbeat, @heartbeat)
     }}
  end

  @impl GenServer
  def handle_call(:report, _from, state) do
    {observations, state} = run(state)
    {:reply, observations, state}
  end

  @impl GenServer
  def handle_info(:report, state) do
    {_observations, state} = run(state)
    schedule(state.heartbeat)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:generated, project_id, result}, state) do
    case result do
      {:ok, dir} ->
        Logger.info("[CmsHarness] generated project #{project_id} at #{dir}")

      {:error, reason} ->
        Logger.warning(
          "[CmsHarness] could not generate project #{project_id}: #{inspect(reason)}"
        )
    end

    {:noreply, %{state | generating: MapSet.delete(state.generating, project_id)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # One exchange: look, say what we saw, keep what the server says we hold.
  defp run(%{known: known, last: last} = state) do
    {observations, known} = observe(known)

    case Device.announce(observations) do
      {:ok, %{working_copies: from_server} = reply} ->
        say(observations, last)
        serve(from_server)
        state = generate(Map.get(reply, :pending_local_projects, []), state)
        # `known` wins: the server's root is where a copy is recorded, not a
        # fact about this disk. It only fills in copies not yet known.
        {observations, %{state | known: Map.merge(from_server, known), last: observations}}

      {:error, reason} ->
        # Debug: `Device.announce/1` already warns.
        Logger.debug(
          "[CmsHarness] working copy report did not reach the server: #{inspect(reason)}"
        )

        # `last` not advanced: the next report that lands is news.
        {observations, %{state | known: known}}
    end
  end

  # Serve the copies the server says this machine carries, not only those a
  # hook has touched: a background agent makes no hooks, and a restart would
  # otherwise drop its copy. Only roots on disk, and only when there is a
  # `CopiesSupervisor` to start them under (reporting works without one).
  defp serve(from_server) do
    case Process.whereis(CmsHarness.CopiesSupervisor) do
      nil ->
        :ok

      _pid ->
        for {id, root} <- from_server, is_binary(root), ServedRoots.matches?(root, id) do
          pick_up(root)
        end

        :ok
    end
  end

  defp pick_up(root) do
    case Projects.ensure_started(root) do
      {:ok, _project} ->
        :ok

      {:error, reason} ->
        Logger.debug("[CmsHarness] could not pick up #{root}: #{inspect(reason)}")
    end
  end

  # Generate pending projects the server offered, only with a
  # `CopiesSupervisor` (same guard as `serve/1`). Spawned, not awaited:
  # generation can take minutes and reports must keep flowing.
  defp generate(pending, state) do
    case Process.whereis(CmsHarness.CopiesSupervisor) do
      nil -> state
      _pid -> Enum.reduce(pending, state, &generate_one/2)
    end
  end

  defp generate_one(%{id: id} = project, state) do
    if MapSet.member?(state.generating, id) do
      state
    else
      reporter = self()

      Task.start(fn ->
        send(reporter, {:generated, id, generate_safely(project)})
      end)

      %{state | generating: MapSet.put(state.generating, id)}
    end
  end

  # Rescued: a raising unlinked task would never free `id` from `generating`,
  # and that project could never be retried.
  defp generate_safely(project) do
    Generator.run(project)
  rescue
    error -> {:error, {:crashed, Exception.format(:error, error, __STACKTRACE__)}}
  end

  @doc """
  What this machine can see, given what it has seen before.

  Returns `{observations, known}` — the report to send, and the memory to keep.
  Separate from the callbacks so the rule can be tested without a process.
  """
  @spec observe(%{optional(String.t()) => String.t()}) ::
          {%{optional(String.t()) => boolean()}, %{optional(String.t()) => String.t()}}
  def observe(known) do
    # Additive: a copy no longer readable stays at its learned root, so it can
    # be reported gone.
    known = Map.merge(known, current_roots())

    {Map.new(known, fn {id, root} -> {id, File.dir?(root)} end), known}
  end

  # Logged at info on change only, so the reporter is visibly alive without a
  # line every beat. Missing copies are named, present ones counted.
  defp say(observations, observations), do: :ok

  defp say(observations, _last) do
    {missing, present} =
      Enum.split_with(observations, fn {_id, present?} -> present? == false end)

    Logger.info(
      "[CmsHarness] reported #{length(present)} checkout(s) present" <>
        gone(missing)
    )
  end

  defp gone([]), do: ", none gone"

  defp gone(missing),
    do: " and #{length(missing)} gone: #{Enum.map_join(missing, ", ", &elem(&1, 0))}"

  # The served copies, or none without `CmsHarness.Registry`. Checked, not
  # rescued, so a real config-reader fault is not reported as "no copies".
  defp current_roots do
    case Process.whereis(CmsHarness.Registry) do
      nil -> %{}
      _pid -> CmsHarness.WorkingCopies.all()
    end
  end

  # `:never` for a reporter whose reports are all driven (`report/1`).
  defp schedule(:never), do: :ok
  defp schedule(delay), do: Process.send_after(self(), :report, delay)
end
