defmodule CodeMySpecWeb.WorkingCopyLive.Liveness do
  @moduledoc """
  What the page knows about an agent being alive, and how it knows it.

  Two engines produce two different facts, and the words have to keep them
  apart — that is rule 1 of story 957. But "Present" and "Idle" on their own
  are a verdict with the evidence removed: they read as the page having decided
  something, and there is no way to tell an Alloy lane that checked in two
  seconds ago from one that checked in an hour ago, because both say Present.

  So every summary carries three things:

    * `label` — the verdict, in the word that belongs to that engine
    * `basis` — *why*, one short clause naming the signal
    * `since` — when the signal last arrived, as elapsed time

  ## The three signals

  An **Alloy agent** is tracked in `Agents.Presence` by its copy's harness
  channel for exactly as long as its process lives, so "Running" is a fact about
  now, not evidence with an age: there is no "since" to print beside it. The
  agent's `lifecycle` (`Agents.with_lifecycle/2`) carries it.

  A **Claude Code agent** has no channel to be present on. It reports over HTTP
  hooks, so what is known is when it last did something. An agent that died five
  minutes ago and one mid-thought produce the same timestamp, and the label says
  so rather than calling either of them present.

  An Alloy agent on duty and **not present** is starting: asked for, being
  restored after a harness restart, or crashed and awaiting its restart —
  whether anything is running is exactly what is not known. Reading engine alone
  made an agent that never came up claim "Running", forever, which is the server
  reporting its own intention back to itself as though it were evidence. Rule 5
  exists to stop precisely that.

  ## Elapsed, not absolute

  "Last heard from Aug 22, 14:03" needs the reader to know what time it is now
  and do subtraction, which is exactly the work they opened the page to avoid.
  Elapsed time answers the question that was actually asked.
  """

  @type summary :: %{label: String.t(), basis: String.t(), since: String.t() | nil}

  @doc """
  What one agent's liveness is, and on what evidence.
  """
  @spec agent(map(), DateTime.t()) :: summary()
  def agent(%{lifecycle: :retired} = agent, now),
    do: %{
      label: "Retired",
      basis: "retired; its seat is empty",
      since: since(agent.retired_at, now)
    }

  # Before engine, so an alloy agent that was turned off never reads as
  # "Running". `list_for_team_status/1` is the caller that hands one in.
  def agent(%{lifecycle: :off} = agent, now),
    do: %{label: "Off", basis: "turned off; not running", since: since(agent.off_at, now)}

  # Not "Starting": nothing is going to start it. Its harness stopped
  # restarting a crash loop and it waits on main — the stuck state an operator
  # has to see, and the one "Starting" hid (8a873265).
  def agent(%{lifecycle: :gave_up} = agent, now) do
    gave_up = agent.gave_up || %{}

    %{
      label: "Gave up — needs main",
      basis: "crashed repeatedly; its harness stopped restarting it" <> reason(gave_up[:reason]),
      since: since(gave_up[:at], now)
    }
  end

  # A terminal Claude Code session (story 1124): present while its session is
  # live on its machine, as its harness reads Claude Code's own agent list.
  def agent(%{engine: :claude_code, engine_session_id: id, lifecycle: :running}, _now)
      when is_binary(id),
      do: %{label: "Running", basis: "its Claude Code session is live on its machine", since: nil}

  def agent(%{engine: :claude_code, engine_session_id: id} = agent, now) when is_binary(id) do
    %{
      label: "Away",
      basis: "no live Claude Code session; what it is sent waits for its next one",
      since: since(agent.updated_at, now)
    }
  end

  # Presence is a fact about now, not evidence with an age: no "since".
  def agent(%{engine: :alloy, lifecycle: :running}, _now),
    do: %{label: "Running", basis: "its process is alive on the harness", since: nil}

  def agent(%{engine: :alloy} = agent, now) do
    %{
      label: "Starting",
      basis: "on duty; its process is not up — being started or restored",
      since: since(agent.updated_at, now)
    }
  end

  # A hooks agent's harness reports it while it lives (`Agents.record_reported/2`)
  # and reaps it when the report stops naming it. That report is the harness's
  # claim, so the agent reads as stopped rather than as recency.
  def agent(%{status: :stopped} = agent, now),
    do: %{
      label: "Stopped",
      basis: "its harness stopped reporting it",
      since: since(agent.updated_at, now)
    }

  def agent(agent, now) do
    %{
      label: "Last heard from",
      basis: "HTTP hooks only — recency, not presence",
      since: since(agent.updated_at, now)
    }
  end

  @doc """
  What a whole working copy's liveness is.

  A copy with no agent is idle, and the basis says which question was asked so
  that "nothing is running here" cannot be confused with "we did not look".
  """
  @spec working_copy([map()], DateTime.t()) :: summary()
  def working_copy([], _now) do
    %{label: "Idle", basis: "no agent reported on this copy", since: nil}
  end

  def working_copy(agents, now) do
    {stopped, on_duty} = Enum.split_with(agents, &stopped?/1)
    {gave_up, on_duty} = Enum.split_with(on_duty, &(&1.lifecycle == :gave_up))
    {alloy, hooks} = Enum.split_with(on_duty, &(&1.engine == :alloy or terminal?(&1)))
    {present, starting} = Enum.split_with(alloy, &(&1.lifecycle == :running))

    case {present, gave_up} do
      {[], [_ | _]} -> stuck(gave_up, now)
      _ -> summarize(present, present ++ hooks, starting, stopped, now)
    end
  end

  # Nothing running and an agent stuck: the copy says so, whatever else is on
  # it, because that is the thing someone has to act on.
  defp stuck(gave_up, now) do
    latest = Enum.max_by(gave_up, &((&1.gave_up || %{})[:at] || &1.updated_at), DateTime)

    %{
      label: "Gave up — needs main",
      basis: label_for_count(length(gave_up)) <> " its harness stopped restarting",
      since: since((latest.gave_up || %{})[:at] || latest.updated_at, now)
    }
  end

  defp terminal?(%{engine: :claude_code, engine_session_id: id}) when is_binary(id), do: true
  defp terminal?(_agent), do: false

  defp reason(nil), do: ""
  defp reason(text), do: " (" <> text <> ")"

  # Turned off, retired, a terminal session that is not live, or a hooks agent
  # its harness no longer reports.
  defp stopped?(%{lifecycle: lifecycle}) when lifecycle in [:off, :retired], do: true

  defp stopped?(%{engine: :claude_code, engine_session_id: id, lifecycle: lifecycle})
       when is_binary(id),
       do: lifecycle != :running

  defp stopped?(%{engine: engine, status: :stopped}) when engine != :alloy, do: true
  defp stopped?(_agent), do: false

  # A copy whose only agents are ones we asked for says so. Rolling them up as
  # "Running" is the same lie one row at a time, and this is the summary most
  # people read — it is what the list shows without opening anything.
  defp summarize([], [], starting, _stopped, now) when starting != [] do
    latest = Enum.max_by(starting, & &1.updated_at, DateTime)

    %{
      label: "Starting",
      basis: label_for_count(length(starting)) <> " on duty, none of their processes up yet",
      since: since(latest.updated_at, now)
    }
  end

  # Nothing starting, nothing confirmed, and `list_for_team_status/1` still
  # handed this copy an agent: the slot's most recently turned-off one, with
  # nothing having replaced it. Distinct from "Idle" — that is no agent ever
  # having reported here at all, which `working_copy([], _now)` above already
  # answers; this is a slot that has one and it is not running.
  defp summarize([], [], [], stopped, now) do
    latest = Enum.max_by(stopped, & &1.updated_at, DateTime)

    %{
      label: "Stopped",
      basis: label_for_count(length(stopped)) <> " turned off or no longer reported",
      since: since(latest.updated_at, now)
    }
  end

  defp summarize([], confirmed, _starting, _stopped, now) do
    latest = Enum.max_by(confirmed, & &1.updated_at, DateTime)

    %{
      label: "Last heard from",
      basis: label_for_count(length(confirmed)) <> ", reporting over hooks",
      since: since(latest.updated_at, now)
    }
  end

  defp summarize(present, _confirmed, _starting, _stopped, _now) do
    %{
      label: "Running",
      basis: label_for_count(length(present)) <> " alive on the harness",
      since: nil
    }
  end

  defp label_for_count(1), do: "1 agent"
  defp label_for_count(n), do: "#{n} agents"

  @doc """
  Elapsed time, said the way somebody glancing at a list would say it.

  Returns nil for a nil timestamp rather than a placeholder, so a caller that
  has no signal renders nothing instead of the word "never" — which is a claim,
  and a different one from "we have not heard yet".
  """
  @spec since(DateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def since(nil, _now), do: nil

  def since(at, now) do
    now |> DateTime.diff(at, :second) |> elapsed()
  end

  # Negative means the timestamp is ahead of us — clock skew between the box
  # that stamped it and this one. "just now" is the honest reading; a negative
  # duration printed literally reads as a bug in the page.
  defp elapsed(seconds) when seconds < 60, do: "just now"
  defp elapsed(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m ago"
  defp elapsed(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h ago"
  defp elapsed(seconds), do: "#{div(seconds, 86_400)}d ago"
end
