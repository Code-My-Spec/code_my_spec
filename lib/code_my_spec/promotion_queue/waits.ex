defmodule CodeMySpec.PromotionQueue.Waits do
  @moduledoc """
  Whether an agent is waiting on the promotion queue: reads of the queue's rows
  for `Agents`, which must not depend on the queue itself (that pulls in the
  gate: Promotion, Analysis, Validation).
  """

  use Boundary, top_level?: true, deps: [CodeMySpec.PromotionQueue.Entry, CodeMySpec.Repo]

  import Ecto.Query

  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.Repo

  @open [:queued, :gating]

  @doc """
  The open candidate this agent asked for, or nil (criterion 2017).

  `:queued` and `:gating` both mean the landing or the ejection is the queue's
  to deliver, and the requester is told when it is. An entry the landing already
  resolved is not this: the agent has a turn to take about it.

  Read by `Agents.Waiting` so an agent waiting on a queued landing is not
  treated as idle and nudged.
  """
  @spec awaited_by(Ecto.UUID.t()) :: Entry.t() | nil
  def awaited_by(agent_id) do
    Repo.one(
      from(e in Entry,
        where:
          e.requested_by_agent_id == type(^agent_id, :binary_id) and
            e.status in ^@open,
        order_by: [asc: e.inserted_at],
        limit: 1
      )
    )
  end

  @doc """
  The task-scoped `awaited_by/1`: is this agent waiting on the queue for
  `subject`?

  A `promote_issue`/`story_promoted` task names its issue or story, and only an
  open entry for that same subject means the task's wait is the queue's.
  """
  @spec open_for(Ecto.UUID.t(), String.t(), String.t()) :: boolean()
  def open_for(agent_id, subject_type, subject_id) do
    Repo.exists?(
      from(e in Entry,
        where:
          e.requested_by_agent_id == type(^agent_id, :binary_id) and
            e.status in ^@open and e.subject_type == ^subject_type and
            e.subject_id == ^subject_id,
        limit: 1
      )
    )
  end

  @doc """
  What the project's promotion queue is doing, for the machinery report
  (criterion 2482): how many candidates wait, the commit it is gating, and why
  it cannot gate when it cannot.

  Read without asking the worker: the machinery report is built on every
  check-in, and a call into a worker busy landing a batch would hold it up.
  """
  @spec status(Ecto.UUID.t()) :: %{
          queued: non_neg_integer(),
          gating: String.t() | nil,
          blocked: %{reason: String.t(), since: DateTime.t()} | nil
        }
  def status(project_id) do
    counts =
      Repo.all(
        from(e in Entry,
          where: e.project_id == type(^project_id, :binary_id) and e.status in ^@open,
          select: {e.status, e.commit},
          order_by: [asc: e.inserted_at]
        )
      )

    %{
      queued: Enum.count(counts, &match?({:queued, _}, &1)),
      gating: Enum.find_value(counts, fn {status, commit} -> status == :gating && commit end),
      blocked: :persistent_term.get({__MODULE__, :blocked, project_id}, nil)
    }
  end

  @doc "The queue could not gate, and why; the first time it said so is kept."
  @spec record_blocked(Ecto.UUID.t(), String.t()) :: :ok
  def record_blocked(project_id, reason) do
    key = {__MODULE__, :blocked, project_id}
    previous = :persistent_term.get(key, nil)
    blocked = %{reason: reason, since: (previous || %{since: DateTime.utc_now()}).since}

    # A write to persistent terms is global work; the queue rechecks every two
    # minutes, so only a change is written.
    if blocked != previous, do: :persistent_term.put(key, blocked)
    :ok
  end

  @doc "The queue can gate again."
  @spec clear_blocked(Ecto.UUID.t()) :: :ok
  def clear_blocked(project_id) do
    key = {__MODULE__, :blocked, project_id}
    if :persistent_term.get(key, nil), do: :persistent_term.erase(key)
    :ok
  end
end
