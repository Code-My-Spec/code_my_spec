defmodule CodeMySpecWeb.WorkingCopyLive.Liveness do
  @moduledoc """
  What the page knows about an agent being alive, and how it knows it.

  Two engines produce two different facts, and the words have to keep them
  apart — that is rule 1 of story 957. But "Present" and "Idle" on their own
  are a verdict with the evidence removed: they read as the page having decided
  something, and there is no way to tell a Pi lane that checked in two seconds
  ago from one that checked in an hour ago, because both say Present.

  So every summary carries three things:

    * `label` — the verdict, in the word that belongs to that engine
    * `basis` — *why*, one short clause naming the signal
    * `since` — when the signal last arrived, as elapsed time

  ## The three signals

  A **Pi lane** is tracked in Presence on the harness channel and joined for
  exactly as long as its process lives, so its liveness is a fact about now.
  `record_reported/2` is a projection of that Presence, and it touches the row —
  which makes `updated_at` the moment the harness last confirmed the lane, and
  the honest thing to print next to "Running".

  A **Claude Code agent** has no channel to be present on. It reports over HTTP
  hooks, so what is known is when it last did something. An agent that died five
  minutes ago and one mid-thought produce the same timestamp, and the label says
  so rather than calling either of them present.

  An agent we **asked for** is neither. `start_agent/2` writes a row at
  `:starting` and only `record_reported/2` moves it to `:running`, so a
  `:starting` row is a request no device has confirmed — the config was minted,
  and whether anything came up is exactly what is not known. That is why status
  is checked before engine here: reading engine alone made an agent that never
  became a lane claim "Running · present on the harness channel", forever,
  which is the server reporting its own intention back to itself as though it
  were evidence. Rule 5 exists to stop precisely that, and this was the one case
  where the page said everything was fine.

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
  def agent(%{status: :starting} = agent, now) do
    %{
      label: "Starting",
      basis: "we asked for this one; no harness has confirmed it",
      since: since(agent.updated_at, now)
    }
  end

  def agent(%{engine: :pi} = agent, now) do
    %{
      label: "Running",
      basis: "present on the harness channel",
      since: since(agent.updated_at, now)
    }
  end

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
    confirmed = Enum.filter(agents, &(&1.status != :starting))
    summarize(Enum.filter(confirmed, &(&1.engine == :pi)), confirmed, agents, now)
  end

  # A copy whose only agents are ones we asked for says so. Rolling them up as
  # "Running" is the same lie one row at a time, and this is the summary most
  # people read — it is what the list shows without opening anything.
  defp summarize([], [], starting, now) do
    latest = Enum.max_by(starting, & &1.updated_at, DateTime)

    %{
      label: "Starting",
      basis: label_for_count(length(starting)) <> " asked for, none confirmed yet",
      since: since(latest.updated_at, now)
    }
  end

  defp summarize([], confirmed, _agents, now) do
    latest = Enum.max_by(confirmed, & &1.updated_at, DateTime)

    %{
      label: "Last heard from",
      basis: label_for_count(length(confirmed)) <> ", reporting over hooks",
      since: since(latest.updated_at, now)
    }
  end

  defp summarize(present, _confirmed, _agents, now) do
    latest = Enum.max_by(present, & &1.updated_at, DateTime)

    %{
      label: "Running",
      basis: label_for_count(length(present)) <> " present on the harness channel",
      since: since(latest.updated_at, now)
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
