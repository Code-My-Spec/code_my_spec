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

  @impl GenServer
  def init(%Scope{active_account_id: account_id} = scope) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, AgentHarness.lanes_topic(account_id))
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

  def handle_info(_message, scope), do: {:noreply, scope}

  defp report(%Scope{active_account_id: account_id}) do
    agents =
      account_id
      |> AgentHarness.lanes_topic()
      |> Presence.list()
      |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas end)
      |> Enum.map(&lane/1)

    Logger.debug("[LaneReporter] reporting #{length(agents)} lane(s) to the server")
    AgentHarness.relay_event(account_id, "agents_running", %{"agents" => agents})
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
