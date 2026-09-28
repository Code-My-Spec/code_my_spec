defmodule CmsHarness.WorkingCopyReporter do
  @moduledoc """
  Keeps saying which of this machine's checkouts are still on disk.

  `CmsHarness.Device.announce/1` carries the observation; this is what computes
  it and what makes it happen more than once.

  ## The two things it has to remember, and why neither is optional

  The obvious implementation is one `File.dir?` over
  `CmsHarness.WorkingCopies.all/0`. It is wrong twice, and both times in exactly
  the case the story is about.

  **A vanished copy stops naming itself.** That map is built by reading
  `.cms_harness.json` out of each root, and the config file lives *inside* the
  checkout — so a removed worktree takes it with it, and the entry does not turn
  `false`, it disappears. An unmentioned copy is treated by the server as no
  news, which is silence, which is the reading this whole model exists to stop
  being fatal. So every copy that has ever been readable stays in `known`, and
  removal is inferred from the directory going away, never from the config file
  going away.

  **A restarted harness has served nothing yet.** `WorkingCopies.all/0` comes
  from `Projects.list/0`, which is the roots this harness has been *asked* to
  serve, and it is asked by a hook arriving. After a restart that list holds the
  copies somebody is actively working in — and the copy whose worktree was
  deleted is precisely the one nobody will work in again. Left to itself the
  harness would look everywhere except at the thing it was watching for.

  The server closes that: `announce/1` answers with the copies attached to this
  device, and those are merged into `known`. Self-correcting across restarts,
  with no state to persist anywhere.

  ## Why a timer

  There is no event to wait for. A worktree is removed by `git worktree remove`
  or `rm -rf`, neither of which tells us anything, and the copy it held stops
  being scanned at that exact moment — nothing happens in a directory that is
  not there. The one signal that would have carried the news is the signal that
  stops.

  Watching the filesystem is the alternative and it is worse: a watch per root
  that has to survive the root disappearing out from under it, on three
  platforms, to learn what a `File.dir?` answers in microseconds.

  ## Why it lives in `CmsHarness` and not the local web app

  `CodeMySpecLocalWeb.LaneReporter` is the same shape one level down — a
  heartbeat reporting a whole set — and would have been the obvious home. It is
  the wrong one: a light harness (`CMS_HARNESS=1`) starts only
  `CmsHarness.Supervisor`, with no Repo, no Presence and no local web app. That
  is the sprite, which is precisely the machine whose checkouts get thrown away,
  so a reporter it does not start would cover every box except the one that
  needed it.

  ## Reporting is not deciding

  Nothing here removes anything. The report raises a warning on the server and
  clears it again if the path comes back; offboarding is a person's act. That
  separation is the point of the model this replaced, which deleted derived
  state on a timer and got it wrong for two agents who were mid-session.
  """

  use GenServer

  require Logger

  alias CmsHarness.Device
  alias CmsHarness.Projects
  alias CmsHarness.Projects.Generator
  alias CmsHarness.ServedRoots

  # Slower than `LaneReporter`'s 30s, deliberately. Lanes come and go inside a
  # single sitting and the page renders them live; a checkout is removed rarely,
  # and nothing downstream acts on the news automatically, so there is no reader
  # this cadence keeps waiting. It is also a directory stat per copy on
  # somebody's laptop.
  @heartbeat :timer.minutes(2)

  # Start the authoritative roster exchange as soon as the supervision tree
  # exists. Credentials can bootstrap from durable served-root hints without
  # first starting channels, so an offline offboard stays offboarded.
  @first_report 0

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: name(opts))

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)

  @doc """
  Report now and wait for it, rather than on the next tick.

  A call rather than a cast so a caller — a test, or anything with reason to
  believe the picture just changed — knows the report has actually been made
  before it looks at the result. Returns what it told the server.
  """
  @spec report(GenServer.server()) :: %{optional(String.t()) => boolean()}
  def report(server \\ __MODULE__), do: GenServer.call(server, :report, 30_000)

  @impl GenServer
  def init(opts) do
    # `:never` leaves every report to the caller, for a rig that drives them.
    case Keyword.get(opts, :first_report, @first_report) do
      :never -> :ok
      delay -> schedule(delay)
    end

    # `known` is seedable because it is genuinely restorable state — "copies
    # this harness has served, and where" — rather than a test hook. A caller
    # that already has the answer can hand it over instead of waiting for the
    # server to say.
    #
    # `last` is the previous report, held only so a repeat can be recognised and
    # not said twice. `nil` rather than `%{}`: having reported nothing is a
    # thing that happened, and is worth one line.
    #
    # `generating` is which pending projects already have a generation task in
    # flight — without it, a project that takes longer to generate than the
    # 2-minute heartbeat would get a second `Generator.run/1` launched onto the
    # same directory before the first finished.
    {:ok, %{known: Keyword.get(opts, :known, %{}), last: nil, generating: MapSet.new()}}
  end

  @impl GenServer
  def handle_call(:report, _from, state) do
    {observations, state} = run(state)
    {:reply, observations, state}
  end

  @impl GenServer
  def handle_info(:report, state) do
    {_observations, state} = run(state)
    schedule(@heartbeat)
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
        # `known` wins. A root from the server says where a copy is *recorded*,
        # which is not a claim about this machine — so it fills in copies we do
        # not know yet and never replaces one we were handed or read off this
        # disk. Merged the other way, a copy recorded at a root this machine
        # does not have got stat'ed at that root and reported missing by the
        # very machine it was sitting on.
        {observations, %{state | known: Map.merge(from_server, known), last: observations}}

      {:error, reason} ->
        # Debug, not warning. `Device.announce/1` already logs at warning; a box
        # offline for an afternoon would otherwise put the same line in
        # harness.log every two minutes.
        Logger.debug(
          "[CmsHarness] working copy report did not reach the server: #{inspect(reason)}"
        )

        # `last` is deliberately not advanced. The report did not land, so the
        # next one that does is news even if it says the same thing.
        {observations, %{state | known: known}}
    end
  end

  # Pick up the copies the server says this machine is carrying.
  #
  # Until this existed, a copy was adopted only by `Projects.ensure_started/1`
  # on its **first hook request** — so a checkout became served when somebody
  # opened a session in it, and never otherwise. That is fine for a person and
  # wrong for everything else: a background agent makes no hook requests, and a
  # worktree created *for* an agent has nobody sitting in it to make one.
  #
  # The consequence is a harness restart. Every rebuild restarts it, and every
  # restart silently dropped every copy without a live session in its directory
  # — the agents on them kept their `running` rows and became unreachable, and
  # the only thing that ever said so was a message failing to deliver. Three
  # times in one day on this machine, twice against an agent the owner was
  # actively trying to talk to.
  #
  # The server already answers this. `Device.announce/1` replies with the copies
  # this device holds, and the reporter has always merged them into `known` and
  # used them for nothing else. Story 1014's criterion 2872 is called "A harness
  # looks where the server tells it, not only where it has been" — this is that
  # sentence applied to serving rather than only to reporting.
  #
  # Only roots that are on disk. A copy the server remembers and the machine no
  # longer has is exactly what the missing-checkout report is for, and starting
  # a subtree to watch a directory that is not there would turn a clean answer
  # into a crash loop.
  # Only when there is somewhere to put a subtree. `current_roots/0` above
  # guards the same way and for the same reason: this reporter runs in trees
  # that do not have the whole harness under them, and reporting is useful
  # without serving. Without the guard the `GenServer.call` into a supervisor
  # that is not there kills the reporter — so a machine that could still have
  # said which of its checkouts had gone silent stops saying anything.
  defp serve(from_server) do
    case Process.whereis(CmsHarness.ProjectSupervisor) do
      nil ->
        :ok

      _pid ->
        for {id, root} <- from_server, is_binary(root), ServedRoots.matches?(root, id) do
          case Projects.ensure_started(root) do
            {:ok, _project} ->
              :ok

            {:error, reason} ->
              Logger.debug("[CmsHarness] could not pick up #{root}: #{inspect(reason)}")
          end
        end

        :ok
    end
  end

  # A pending project the server offered, generated and onboarded onto this
  # machine — same guard as `serve/1` and for the same reason: a harness with
  # no `ProjectSupervisor` (the light-harness/sprite path, or any process that
  # only embeds this reporter for its reporting) has nowhere to serve a
  # generated project into and must not attempt to become the thing serving
  # one. `DeviceController` already excludes `kind: :cloud` devices from ever
  # being offered a pending project at all — this guard covers a `kind: :local`
  # process that nonetheless has no project supervisor, which the server
  # cannot see from its own side.
  #
  # Spawned, not awaited: `Generator.run/1` shells out through several `mix`
  # tasks and can run for minutes, and this reporter has a report due again in
  # two — blocking here would mean a machine mid-generation stops answering
  # "which of my checkouts are still on disk" for as long as generation takes.
  defp generate(pending, state) do
    case Process.whereis(CmsHarness.ProjectSupervisor) do
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

  # Rescued at the boundary rather than left to crash the task: an unlinked
  # `Task` that raises simply vanishes, and a vanished task never sends the
  # message that frees `id` back out of `generating` — so the one project that
  # hit an unexpected error would be the one project this harness could never
  # retry again, even after whatever was wrong got fixed. `Generator.run/1`
  # itself returns `{:error, _}` for every failure it anticipates; this is only
  # for the ones it does not, chief among them `System.cmd/3` raising outright
  # when the machine has no `mix` on its `PATH` at all — step 1.5's exact gap.
  defp generate_safely(project) do
    Generator.run(project)
  rescue
    error -> {:error, {:crashed, Exception.format(:error, error, __STACKTRACE__)}}
  end

  @doc """
  What this machine can see, given what it has seen before.

  Returns `{observations, known}` — the report to send, and the memory to keep.
  Separated from the server callbacks so the half with the rule in it can be
  exercised without a process.
  """
  @spec observe(%{optional(String.t()) => String.t()}) ::
          {%{optional(String.t()) => boolean()}, %{optional(String.t()) => String.t()}}
  def observe(known) do
    # Additive. A copy currently readable is learned; one that is not stays at
    # the root we learned it at, which is what lets us say it is gone rather
    # than say nothing about it.
    known = Map.merge(known, current_roots())

    {Map.new(known, fn {id, root} -> {id, File.dir?(root)} end), known}
  end

  # Says what was reported, because a producer nobody can see is a producer
  # nobody can tell has stopped. The server-side handler for this shape has been
  # built twice on this project with nothing pushing into it, and both times the
  # specs passed because they constructed the payload themselves — the gap showed
  # up only as a page that was quietly always right.
  #
  # On change rather than on every beat, and at info rather than debug, because
  # `harness.log` carries info and above. Debug for the healthy case made the
  # only evidence the reporter was alive the absence of a complaint, which is the
  # same unfalsifiable shape it exists to remove. A line every two minutes
  # forever is the opposite failure.
  #
  # Missing copies are named, present ones counted: eight healthy roots listed
  # out is noise, and the one that is gone is the whole message.
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

  # The copies this harness is serving, or none when it is not serving anything.
  #
  # `CmsHarness.WorkingCopies.all/0` reads `CmsHarness.Registry`, which does not
  # exist in a process that never started the harness supervisor — every test
  # run, and anything embedding these modules. Asked rather than rescued: a
  # rescue here would also swallow a real fault in the config reader and report
  # it as "no copies", which is indistinguishable from a harness with nothing to
  # say.
  defp current_roots do
    case Process.whereis(CmsHarness.Registry) do
      nil -> %{}
      _pid -> CmsHarness.WorkingCopies.all()
    end
  end

  defp schedule(delay), do: Process.send_after(self(), :report, delay)
end
