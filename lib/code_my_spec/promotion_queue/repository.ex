defmodule CodeMySpec.PromotionQueue.Repository do
  @moduledoc """
  The queue's rows: what is waiting, what is being gated, and what happened to
  each candidate. Every status change is broadcast on
  `"promotion_queue:<project_id>"` as `{:promotion_queue, entry}`, which is what
  a caller waiting on its own candidate listens for.
  """

  import Ecto.Query

  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.Repo

  @open [:queued, :gating]

  @doc """
  Queue `attrs` for its project. The same copy at the same commit already
  queued or being gated is that entry, not a second one — a promote repeated
  after a harness restart asks for what is already in hand. A copy with a
  candidate still waiting (not yet in a batch) has that candidate moved to the
  new commit, keeping its place — the copy moved on, and gating the old commit
  would land work its agent has already replaced.
  """
  @spec enqueue(map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(%{project_id: project_id, working_copy_id: copy_id, commit: commit} = attrs) do
    case open_at(project_id, copy_id, commit) do
      %Entry{} = open -> {:ok, open}
      nil -> enqueue_new(attrs)
    end
  end

  # Transactional, and the match re-checked under its own lock: a plain
  # read-then-write here raced the worker reserving the very row this found
  # -- `move/3` holds a `FOR UPDATE` lock across the whole reservation, so an
  # unlocked `Repo.update()` on the same row would simply block until that
  # commits and then overwrite it anyway, retargeting an entry the worker had
  # already started building, gating and landing under its old commit (issue
  # 97b27e62: the new promotion's own requester then heard nothing true about
  # it -- the worker's outcome described the stale candidate it was actually
  # processing). Re-reading `waiting_for_copy/2` under this transaction's own
  # lock means that block ends with the row already moved off `:queued`, so
  # it is correctly left alone and a fresh entry is inserted instead.
  defp enqueue_new(%{project_id: project_id, working_copy_id: copy_id} = attrs) do
    Repo.transaction(fn ->
      case waiting_for_copy(project_id, copy_id) do
        nil ->
          case attrs |> Entry.enqueue_changeset() |> Repo.insert() do
            {:ok, entry} -> entry
            {:error, error} -> Repo.rollback(error)
          end

        %Entry{} = waiting ->
          changeset =
            Ecto.Changeset.change(waiting,
              commit: attrs.commit,
              subject_type: attrs[:subject_type],
              subject_id: attrs[:subject_id],
              requested_by_agent_id: attrs[:requested_by_agent_id],
              restart: attrs.restart
            )

          case Repo.update(changeset) do
            {:ok, entry} -> entry
            {:error, error} -> Repo.rollback(error)
          end
      end
    end)
    |> broadcast()
  end

  defp open_at(project_id, copy_id, commit) do
    Repo.one(
      from(e in Entry,
        where:
          e.project_id == ^project_id and e.working_copy_id == ^copy_id and
            e.commit == ^commit and e.status in ^@open,
        limit: 1
      )
    )
  end

  # `FOR UPDATE`: this is the read a concurrent `move/3` reservation's own
  # lock is meant to be waited out by (see `enqueue_new/1`'s moduledoc
  # comment) -- an unlocked read here would see the row as still `:queued`
  # while that reservation is in flight and retarget it regardless.
  defp waiting_for_copy(project_id, copy_id) do
    Repo.one(
      from(e in Entry,
        where:
          e.project_id == ^project_id and e.working_copy_id == ^copy_id and e.status == :queued,
        lock: "FOR UPDATE",
        limit: 1
      )
    )
  end

  @doc """
  The open candidate this agent asked for, or nil (criterion 2017).

  `:queued` and `:gating` both mean the landing or the ejection is the queue's
  to deliver, and the requester is told when it is. An entry the landing already
  resolved is not this: the agent has a turn to take about it.

  Read by `Agents.Waiting` so an agent waiting on a queued landing is not
  treated as idle and nudged. It is here rather than in that module because the
  queue owns its rows; `PromotionQueue` does not depend on `Agents`, so this
  direction is not a cycle.
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

  @doc "The candidates waiting for a batch, oldest first, at most `limit`."
  @spec queued(Ecto.UUID.t(), pos_integer()) :: [Entry.t()]
  def queued(project_id, limit) do
    Repo.all(
      from(e in Entry,
        where: e.project_id == ^project_id and e.status == :queued,
        order_by: [asc: e.inserted_at, asc: e.id],
        limit: ^limit
      )
    )
  end

  @doc "1 for the candidate at the front, counting the ones being gated."
  @spec position(Entry.t()) :: pos_integer()
  def position(%Entry{project_id: project_id, inserted_at: inserted_at}) do
    ahead =
      Repo.aggregate(
        from(e in Entry,
          where:
            e.project_id == ^project_id and e.status in ^@open and e.inserted_at < ^inserted_at
        ),
        :count
      )

    ahead + 1
  end

  @doc "Projects with candidates not yet landed or ejected."
  @spec open_projects() :: [Ecto.UUID.t()]
  def open_projects do
    Repo.all(from(e in Entry, where: e.status in ^@open, distinct: true, select: e.project_id))
  end

  @doc """
  Candidates a batch held when its worker went away. Nothing was landed for
  them, so they wait again.
  """
  @spec requeue_gating(Ecto.UUID.t()) :: :ok
  def requeue_gating(project_id) do
    from(e in Entry, where: e.project_id == ^project_id and e.status == :gating)
    |> Repo.all()
    |> Enum.each(&move(&1, :queued, %{batch_id: nil}))
  end

  @spec get(Ecto.UUID.t()) :: Entry.t() | nil
  def get(id), do: Repo.get(Entry, id)

  @doc "Move one entry to `status`, with any of `:batch_id` and `:result`."
  @spec move(Entry.t(), atom(), map()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def move(%Entry{} = entry, status, attrs \\ %{}) do
    result =
      Repo.transaction(fn ->
        CodeMySpec.Analysis.ValidationHolds.lock(entry.project_id)

        # Re-fetched and locked rather than trusting the struct the caller is
        # holding: `enqueue_new/1`'s `waiting_for_copy/2` retargets a still
        # `:queued` entry to a new commit/subject in place, with no lock of
        # its own, so a promote on the same working copy arriving between
        # this entry being read by `reserve_next/1` and this move committing
        # could overwrite its commit and subject out from under a reservation
        # already in flight -- the worker then built, gated and landed the
        # entry's *old* commit while its row claimed the new one, and the
        # new promotion's own requester never heard a true outcome (issue
        # 97b27e62). Locking here makes that concurrent update block until
        # this transaction commits the status change; once it is no longer
        # `:queued`, `waiting_for_copy/2` stops matching it and a genuinely
        # new entry is created instead.
        locked = Repo.one!(from(e in Entry, where: e.id == ^entry.id, lock: "FOR UPDATE"))

        if status == :gating and locked.status != :gating and
             not CodeMySpec.Analysis.ValidationHolds.promotion_allowed?(locked.project_id),
           do: Repo.rollback(:validation_held)

        if status == :gating do
          case CodeMySpec.Promotion.HandoffGate.check(locked.project_id, locked.working_copy_id) do
            :ok -> :ok
            {:error, _} -> Repo.rollback(:completion_handoff_pending)
          end
        end

        case locked |> Entry.status_changeset(Map.put(attrs, :status, status)) |> Repo.update() do
          {:ok, updated} -> updated
          {:error, error} -> Repo.rollback(error)
        end
      end)

    broadcast(result)
  end

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(project_id), do: "promotion_queue:#{project_id}"

  defp broadcast({:ok, %Entry{} = entry} = ok) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      topic(entry.project_id),
      {:promotion_queue, entry}
    )

    ok
  end

  defp broadcast(error), do: error
end
