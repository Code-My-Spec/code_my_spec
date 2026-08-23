defmodule CodeMySpecLocalWeb.LaneReporter do
  @moduledoc """
  Tells the server what agents are running on this box.

  The server has had an `agents_running` handler since the working-copies page
  was built, and **nothing ever pushed one** — so every copy read as idle no
  matter how many agents were on it, and the whole liveness distinction the page
  is about had no data to distinguish. This is the producer.

  ## Why a process and not a channel

  A lane cannot report its own departure. The report is a whole-set reconcile
  (anything absent is marked stopped), and the moment that matters most is the
  *last* lane going away — at which point no lane channel is left to say so. So
  the reporter has to outlive the lanes, and it is started per account beside
  `HarnessProxySocket`.

  ## Why a process and not the proxy

  Presence belongs to the local web app; `CodeMySpec.AgentHarness` may not
  reference it, and the boundary is right to say so. The proxy is transport. So
  the set is composed here and handed over as an ordinary relay event, the same
  way a transcript line goes up.

  ## Where the set comes from

  Every lane tracks itself twice: on its own session topic, and on the account's
  lanes topic (`AgentHarness.lanes_topic/1`) keyed `<external_id>|<role>`. The
  second is what makes "everything on this box" a single `Presence.list/1`.
  Still Presence, so a lane still leaves by its process dying and nothing has to
  expire.

  Reads the list fresh on each diff rather than folding the diff into state: the
  diff says something changed, and the list is the answer. Folding means keeping
  a second copy of Presence's own state and being wrong when they disagree.

  ## Why it also reports on a timer

  A diff only fires when a lane joins or leaves, so a box where nothing happens
  says nothing — and "nothing happened" is indistinguishable from "the report
  was lost" or "the socket was down when it went out". Pushes are dropped rather
  than queued while disconnected, so a single missed report is permanent until
  something moves.

  That is not hypothetical: an agent `start_agent/2` wrote and no lane ever came
  up for sat claiming presence indefinitely, because no lane joining meant no
  diff meant no reconcile meant nothing to reap the row. The heartbeat bounds
  how long the server can believe something the device would contradict.

  Cheap on purpose. The report is a `Presence.list/1` and a broadcast, and the
  server side is one reconcile per project — the same work a lane joining
  already causes.
  """

  use GenServer

  require Logger

  alias CodeMySpec.AgentHarness
  alias CodeMySpec.Users.Scope
  alias CodeMySpecLocalWeb.Presence

  def start_link(opts) do
    scope = Keyword.fetch!(opts, :scope)
    GenServer.start_link(__MODULE__, scope, name: name(scope))
  end

  defp name(%Scope{active_account_id: account_id}),
    do: Module.concat(__MODULE__, "Account_#{account_id}")

  # Long enough that a quiet box is not chattering, short enough that a row the
  # device would contradict cannot sit there through a coffee break. The page
  # renders elapsed time, so this is also the resolution of "last heard from".
  @heartbeat :timer.seconds(30)

  @impl GenServer
  def init(%Scope{active_account_id: account_id} = scope) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, AgentHarness.lanes_topic(account_id))
    schedule_heartbeat()
    {:ok, scope}
  end

  # A lane joined or left.
  @impl GenServer
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, scope) do
    report(scope)
    {:noreply, scope}
  end

  # The proxy reconnected and wants the current picture.
  def handle_info(:report_running, scope) do
    report(scope)
    {:noreply, scope}
  end

  def handle_info(:heartbeat, scope) do
    report(scope)
    schedule_heartbeat()
    {:noreply, scope}
  end

  def handle_info(_message, scope), do: {:noreply, scope}

  defp schedule_heartbeat, do: Process.send_after(self(), :heartbeat, @heartbeat)

  defp report(%Scope{active_account_id: account_id}) do
    agents =
      account_id
      |> AgentHarness.lanes_topic()
      |> Presence.list()
      |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas end)
      |> Enum.map(&lane/1)

    # Info, not debug. This line is the only evidence that the box told the
    # server anything, and the failure it distinguishes — the server showing
    # every checkout idle — looks identical whether the report was never sent,
    # sent empty, or sent and dropped. At debug level the one signal that
    # separates those three is filtered out of the log somebody goes to read.
    Logger.info("[LaneReporter] reporting #{length(agents)} lane(s): #{summarize(agents)}")

    AgentHarness.relay_event(account_id, "agents_running", %{"agents" => agents})
  end

  defp summarize([]), do: "nothing running"

  defp summarize(agents) do
    Enum.map_join(agents, ", ", &"#{&1["role"]}@#{&1["working_copy"]}")
  end

  # The shape `Agents.record_reported/2` reconciles against. `role` is what makes
  # two lanes on one checkout two rows instead of one that flickers.
  defp lane(meta) do
    %{
      "working_copy" => meta.working_copy,
      "role" => meta.role,
      "engine" => meta.engine,
      "provider" => meta.provider
    }
  end
end
