defmodule CodeMySpec.PromotionQueue do
  @moduledoc """
  Promotions, queued and landed in batches (promote-queue step 2, John
  2026-10-04).

  An agent's `promote` no longer merges. It records the working copy and the
  commit it is at and answers with its place in the queue, in seconds. The
  project's worker (`Worker`) gates candidates in batches in the project's gate
  copy and lands each green batch on main as an exact, tagged commit
  (`Promotion.land/6`). A red batch is triaged: a lone failure is re-run once,
  findings that belong to one candidate eject it, and anything else is
  bisected. Each candidate's requester is told what happened to it.

  A candidate is certified against the queue head — main plus everything ahead
  of it — which is what the gate copy's batch is, so it does not have to merge
  main itself first.

  Generic: nothing here knows about any project's own release or tooling.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Analysis,
      CodeMySpec.Projects,
      CodeMySpec.Promotion,
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ],
    exports: [Entry, Worker]

  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.PromotionQueue.Worker
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @supervisor CodeMySpec.PromotionQueue.Supervisor

  @doc """
  What `promote` does now: queue the scope's copy, unless it is the main copy
  itself. Main has nothing to merge — its promotion is a restart — so it goes
  straight through `Promotion.promote/3` as before.
  """
  @spec promote(Scope.t(), integer() | nil, keyword()) :: {:ok, map()} | {:error, map()}
  def promote(%Scope{} = scope, story_number, opts \\ []) do
    case promoting_copy(scope) do
      {:ok, %WorkingCopy{main: true}} -> Promotion.promote(scope, story_number, opts)
      _ -> enqueue(scope, story_number, opts)
    end
  end

  @doc """
  `promote/3`, then wait for a queued candidate's outcome — for the doors with
  nobody to message (`promote_sync`, the HTTP wait URL). A candidate still
  queued when `timeout` runs out is answered as queued, with `timed_out: true`.
  """
  @spec promote_and_wait(Scope.t(), integer() | nil, keyword(), timeout()) ::
          {:ok, map()} | {:error, map()}
  def promote_and_wait(%Scope{active_project_id: project_id} = scope, story_number, opts, timeout) do
    # Subscribed before enqueueing: a lone candidate can land before a later
    # subscription would hear it.
    subscribed(project_id, fn ->
      case promote(scope, story_number, opts) do
        {:ok, %{queued: entry} = queued} -> waited(queued, settle(entry, timeout))
        other -> other
      end
    end)
  end

  defp waited(_queued, {:landed, report}), do: report
  defp waited(_queued, {:ok, %Entry{status: :landed} = done}), do: {:ok, %{queue_outcome: done}}

  defp waited(_queued, {:ok, done}),
    do: {:error, %{reason: outcome_text(done), queue_outcome: done}}

  defp waited(queued, {:error, :timeout}), do: {:ok, Map.put(queued, :timed_out, true)}

  @doc "The answer to a `promote/3`, whichever way it went."
  @spec text({:ok, map()} | {:error, map()}) :: String.t()
  def text({:ok, %{queued: _}} = result), do: queued_text(result)
  def text(result), do: Promotion.outcome_text(result)

  @doc """
  Queue the scope's working copy at its HEAD for promotion.

  The cheap checks happen now — a known story, a committed, clean checkout, and
  no blocking problem the copy's own analysis already found at that commit —
  so a refusal still comes back at once. Everything that takes analysis
  happens in the batch.

  `{:ok, %{queued: entry, position: n}}` or `{:error, %{reason: ...}}`.
  """
  @spec enqueue(Scope.t(), integer() | nil, keyword()) :: {:ok, map()} | {:error, map()}
  def enqueue(%Scope{} = scope, story_number, opts \\ []) do
    with {:ok, story} <- story(scope, story_number),
         {:ok, copy} <- promoting_copy(scope),
         {:ok, head} <- clean_head(scope, copy),
         :ok <- Promotion.red_at(%{scope | active_working_copy_id: copy.id}, head),
         {:ok, entry} <-
           Repository.enqueue(%{
             project_id: scope.active_project_id,
             working_copy_id: copy.id,
             commit: head,
             story_number: story && story.number,
             requested_by_agent_id: Keyword.get(opts, :notify),
             restart: Keyword.get(opts, :restart, false)
           }) do
      ensure_worker(scope)
      {:ok, %{queued: entry, position: Repository.position(entry)}}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, %{reason: "could not queue the promotion: #{inspect(changeset.errors)}"}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Wait for `entry` to land or be ejected, for callers with nobody to message
  (`promote_sync`). `{:ok, entry}` with its final status — or, for a landing
  this caller saw happen, `{:landed, report}` with the promotion's own report —
  or `{:error, :timeout}`.
  """
  @spec await(Entry.t(), timeout()) ::
          {:ok, Entry.t()} | {:landed, {:ok, map()}} | {:error, :timeout}
  def await(%Entry{project_id: project_id} = entry, timeout),
    do: subscribed(project_id, fn -> settle(entry, timeout) end)

  defp subscribed(project_id, fun) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, Repository.topic(project_id))

    try do
      fun.()
    after
      Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, Repository.topic(project_id))
    end
  end

  # A landing report already in the mailbox wins over the row, which says only
  # that it landed.
  defp settle(%Entry{id: id}, timeout) do
    receive do
      {:promotion_queue_landed, ^id, report} -> {:landed, report}
    after
      0 -> settle_from_row(id, timeout)
    end
  end

  defp settle_from_row(id, timeout) do
    case Repository.get(id) do
      %Entry{status: status} = done when status in [:landed, :ejected, :cancelled] -> {:ok, done}
      _ -> wait(id, System.monotonic_time(:millisecond) + timeout)
    end
  end

  defp wait(id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:promotion_queue_landed, ^id, report} ->
        {:landed, report}

      {:promotion_queue, %Entry{id: ^id, status: status} = done}
      when status in [:landed, :ejected, :cancelled] ->
        {:ok, done}
    after
      remaining -> {:error, :timeout}
    end
  end

  @doc "A queue entry by id, or nil."
  @spec get(Ecto.UUID.t()) :: Entry.t() | nil
  def get(id), do: Repository.get(id)

  @doc "What to tell the caller that enqueued."
  @spec queued_text({:ok, map()} | {:error, map()}) :: String.t()
  def queued_text({:ok, %{queued: entry, timed_out: true}}) do
    "Still queued after waiting: #{describe(entry)}. It has not landed and was not taken " <>
      "out; the queue is still working on it. Do not promote again to check."
  end

  def queued_text({:ok, %{queued: entry, position: position}}) do
    "Queued for promotion at position #{position}: #{describe(entry)}. Nothing is merged " <>
      "yet. The queue gates it with the candidates ahead of it and lands it on main " <>
      "when that batch is green; you will be told when it lands, or why it was taken " <>
      "out. Keep working; do not promote again to check."
  end

  def queued_text({:error, %{reason: reason}}), do: "Your promotion was not queued. #{reason}"

  @doc "What became of an entry, in a sentence."
  @spec outcome_text(Entry.t()) :: String.t()
  def outcome_text(%Entry{status: :landed, result: result} = entry),
    do: "#{describe(entry)} landed on main#{version(result)}."

  def outcome_text(%Entry{status: :ejected, result: result} = entry),
    do: "#{describe(entry)} was taken out of the queue: #{result["reason"]}"

  def outcome_text(%Entry{status: status} = entry), do: "#{describe(entry)} is #{status}."

  defp version(%{"version" => v}) when is_binary(v), do: " as v#{v}"
  defp version(_), do: ""

  defp describe(%Entry{story_number: nil, commit: commit}),
    do: "commit #{String.slice(commit, 0, 12)}"

  defp describe(%Entry{story_number: number, commit: commit}),
    do: "story #{number} at #{String.slice(commit, 0, 12)}"

  @doc """
  Start the project's worker, or hand a running one the newest scope. Called on
  every enqueue, and at boot for projects with candidates still open.
  """
  @spec ensure_worker(Scope.t()) :: :ok
  def ensure_worker(%Scope{active_project_id: project_id} = scope) do
    case DynamicSupervisor.start_child(@supervisor, {Worker, {project_id, scope}}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        GenServer.cast(pid, {:scope, scope})
        GenServer.cast(pid, :kick)
        :ok
    end
  end

  @doc "Resume every project with candidates still open. Called at boot."
  @spec resume_all() :: :ok
  def resume_all do
    for project_id <- Repository.open_projects(),
        %{} = project <- [CodeMySpec.Repo.get(CodeMySpec.Projects.Project, project_id)] do
      ensure_worker(%Scope{
        active_account_id: project.account_id,
        active_project_id: project.id,
        active_project: project
      })
    end

    :ok
  end

  defp story(_scope, nil), do: {:ok, nil}

  defp story(scope, number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, %{reason: "there is no story #{inspect(number)} in this project."}}
      story -> {:ok, story}
    end
  end

  defp promoting_copy(%Scope{active_working_copy_id: id}) when is_binary(id) do
    case WorkingCopies.fetch(id) do
      {:ok, %WorkingCopy{root: root} = copy} when is_binary(root) -> {:ok, copy}
      _ -> {:error, %{reason: "this checkout has not reported where it is."}}
    end
  end

  defp promoting_copy(_scope),
    do: {:error, %{reason: "no working copy on this scope; nothing to promote."}}

  # A clean, committed checkout, read where it lives.
  defp clean_head(scope, copy) do
    case Runner.precheck(scope, copy.root, copy.id, nil) do
      {:ok, %{head: head}} when is_binary(head) -> {:ok, head}
      {:ok, _} -> {:error, %{reason: "could not read #{copy.root}'s HEAD."}}
      {:error, _} = error -> error
    end
  end
end
