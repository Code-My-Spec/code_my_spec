defmodule CmsHarness.WorkingCopyReporter do
  @moduledoc """
  Keeps saying which of this machine's checkouts are still on disk.

  `CmsHarness.Device.announce/1` carries the observation; this is what computes
  it and what makes it happen more than once.

  ## Why it has to remember

  The obvious implementation is one `File.dir?` over `CmsHarness.WorkingCopies.all/0`,
  and it is wrong in exactly the case the story is about.

  That map is built by reading `.cms_harness.json` out of each root. The config
  file lives **inside** the checkout, so a removed worktree takes it with it —
  and the entry does not become `false`, it disappears. A copy that vanished
  would therefore be *unreported* rather than reported missing, which the server
  correctly treats as "no news", which is silence, which is the one reading this
  whole model exists to stop being fatal.

  So the reporter keeps `id => root` for every copy it has ever managed to read,
  and answers for all of them. Discovery is additive and removal is never
  inferred from the config file going away — only from the directory going away.

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

  # Slower than `LaneReporter`'s 30s, deliberately. Lanes come and go inside a
  # single sitting and the page renders them live; a checkout is removed rarely,
  # and nothing downstream acts on the news automatically, so there is no reader
  # this cadence keeps waiting. It is also a directory stat per copy on
  # somebody's laptop.
  @heartbeat :timer.minutes(2)

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
    schedule()

    # `known` is seedable because it is genuinely restorable state — "copies
    # this harness has served, and where" — not a test hook. A harness that
    # restarts loses it and rebuilds it from discovery on the next tick, which
    # is why nothing persists it; a caller that already has the answer can hand
    # it over instead of waiting.
    {:ok, Keyword.get(opts, :known, %{})}
  end

  @impl GenServer
  def handle_call(:report, _from, known) do
    {observations, known} = observe(known)
    announce(observations)
    {:reply, observations, known}
  end

  @impl GenServer
  def handle_info(:report, known) do
    {observations, known} = observe(known)
    announce(observations)
    schedule()
    {:noreply, known}
  end

  def handle_info(_message, known), do: {:noreply, known}

  @doc """
  What this machine can see, given what it has seen before.

  Returns `{observations, known}` — the report to send, and the memory to keep.
  Separated from the server callbacks so the interesting half can be exercised
  without a process: it is the half with the rule in it.
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

  defp current_roots do
    CmsHarness.WorkingCopies.all()
  rescue
    # Bookkeeping riding along with an announce that has a real job. A machine
    # whose filesystem answered badly still gets to keep its identity, and still
    # reports on the copies it already knew about.
    error ->
      Logger.warning(
        "[CmsHarness] could not read the checkouts this harness serves: #{inspect(error)}"
      )

      %{}
  end

  defp announce(observations) do
    case Device.announce(observations) do
      {:ok, _id} ->
        :ok

      {:error, reason} ->
        # Debug, not warning. `Device.announce/1` already logs at warning; a box
        # offline for an afternoon would otherwise put the same line in
        # harness.log every two minutes.
        Logger.debug(
          "[CmsHarness] working copy report did not reach the server: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp schedule, do: Process.send_after(self(), :report, @heartbeat)
end
