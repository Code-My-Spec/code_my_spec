defmodule CodeMySpec.PromotionQueue do
  @moduledoc """
  Serializes project promotions against origin's configured development branch.
  Each candidate is prepared and certified on its source device; publishing the
  exact certified commit does not require a destination desktop to be online.
  Publication receipts make recovery idempotent, and device synchronization is
  tracked independently. Story and issue QA remain admission and landing gates.

  Local-only fixtures explicitly opt into the legacy checkout landing path.
  A production repository without origin is refused, never silently redirected
  to a desktop checkout.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Analysis,
      CodeMySpec.AppRole,
      CodeMySpec.Issues,
      CodeMySpec.Projects,
      CodeMySpec.Promotion,
      CodeMySpec.PromotionQueue.Entry,
      CodeMySpec.Qa,
      CodeMySpec.Repo,
      CodeMySpec.Stories,
      CodeMySpec.Users.Scope,
      CodeMySpec.WorkingCopies
    ],
    exports: [Worker]

  alias CodeMySpec.AppRole
  alias CodeMySpec.Issues
  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.DeviceSync
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.PromotionQueue.Worker
  alias CodeMySpec.Qa
  alias CodeMySpec.Repo.SandboxAllowance
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @supervisor CodeMySpec.PromotionQueue.Supervisor

  @doc """
  Queue the scope's current commit for source-side certification and publication.
  Main working copies use the same publication gate as other source copies.
  """
  @spec promote(Scope.t(), integer() | nil, keyword()) :: {:ok, map()} | {:error, map()}
  def promote(%Scope{} = scope, story_number, opts \\ []) do
    if Worker.local_only?(scope) and
         match?({:ok, %WorkingCopy{main: true}}, promoting_copy(scope)) do
      Promotion.promote(scope, story_number, opts)
    else
      enqueue(scope, story_number, opts)
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

  defp waited(
         _queued,
         {:ok, %Entry{status: :landed, result: %{"assignment_held" => true}} = done}
       ),
       do:
         {:error,
          %{
            landed: true,
            assignment_held: true,
            landed_commit: done.result["head"],
            reason: outcome_text(done),
            queue_outcome: done
          }}

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

  The cheap checks happen now — a known story, QA passed on the story or issue
  it promotes, a committed, clean checkout, and no blocking problem the copy's
  own analysis already found at that commit — so a refusal still comes back at
  once. Everything that takes analysis happens in the batch.

  `{:ok, %{queued: entry, position: n}}` or `{:error, %{reason: ...}}`.
  """
  @spec enqueue(Scope.t(), integer() | nil, keyword()) :: {:ok, map()} | {:error, map()}
  def enqueue(%Scope{} = scope, story_number, opts \\ []) do
    with :ok <- main_copy(),
         {:ok, story} <- story(scope, story_number),
         {:ok, copy} <- promoting_copy(scope),
         {:ok, head} <- clean_head(scope, copy),
         {:ok, subject} <- subject(scope, story, copy, Keyword.get(opts, :issue_id), head),
         {:ok, entry} <- queue_or_resume(scope, copy, head, subject, opts) do
      ensure_worker(scope)
      {:ok, %{queued: entry, position: Repository.position(entry)}}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, %{reason: "could not queue the promotion: #{inspect(changeset.errors)}"}}

      {:error, _} = error ->
        error
    end
  end

  # A copy's own app runs on a clone of main's database: a worker started there
  # would gate and publish beside main's.
  defp main_copy do
    if AppRole.main_copy?(),
      do: :ok,
      else:
        {:error,
         %{
           reason:
             "this is a working copy's own app, not main's: promote through main's harness, " <>
               "which queues it where the promotion runs."
         }}
  end

  defp queue_or_resume(scope, copy, head, subject, opts) do
    attrs =
      Map.merge(subject_attrs(subject), %{
        project_id: scope.active_project_id,
        working_copy_id: copy.id,
        commit: head,
        requested_by_agent_id: Keyword.get(opts, :notify),
        restart: Keyword.get(opts, :restart, false),
        fresh: Keyword.get(opts, :fresh, false)
      })

    case Repository.reopen_held(attrs) do
      {:ok, entry} ->
        {:ok, entry}

      :none ->
        with :ok <- qa_passed(scope, subject, head),
             :ok <- assigned_issues_clear(scope, copy, subject),
             :ok <- Promotion.red_at(%{scope | active_working_copy_id: copy.id}, head) do
          Repository.enqueue(attrs)
        end

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

      # A landing is answered by its report, which follows the row's broadcast.
      {:promotion_queue, %Entry{id: ^id, status: status} = done}
      when status in [:ejected, :cancelled] ->
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
  def outcome_text(
        %Entry{status: :landed, result: %{"assignment_held" => true} = result} = entry
      ),
      do:
        "#{describe(entry)} landed on main, but story completion and assignment release are held. #{result["reason"]} Do not re-merge this candidate."

  def outcome_text(%Entry{status: :landed, result: result} = entry),
    do: "#{describe(entry)} landed on main#{version(result)}."

  def outcome_text(%Entry{status: :ejected, result: result} = entry),
    do: "#{describe(entry)} was taken out of the queue: #{result["reason"]}"

  def outcome_text(%Entry{status: status} = entry), do: "#{describe(entry)} is #{status}."

  defp version(%{"version" => v}) when is_binary(v), do: " as v#{v}"
  defp version(_), do: ""

  defp describe(%Entry{subject_type: nil, commit: commit}),
    do: "commit #{String.slice(commit, 0, 12)}"

  defp describe(%Entry{} = entry), do: Entry.describe(entry)

  @doc """
  Start the project's worker, or hand a running one the newest scope. Called on
  every enqueue, and at boot for projects with candidates still open.
  """
  @spec ensure_worker(Scope.t()) :: :ok
  def ensure_worker(%Scope{active_project_id: project_id} = scope) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {Worker, {project_id, scope, SandboxAllowance.owners()}}
         ) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, pid}} ->
        SandboxAllowance.grant(pid)
        GenServer.cast(pid, {:scope, scope})
        GenServer.cast(pid, :kick)
        :ok
    end
  end

  @doc """
  A working copy's harness joined. An idle worker looks at its queue again: a
  candidate waits, untaken, until main and the gate copy can both be read, and
  a join is what changes that (a gate copy minted for the first batch comes up
  a minute or so after it is made). A batch already gating in the gate copy
  asks the gate again: runs it asked for may have gone with the connection
  that just went.
  """
  @spec copy_joined(Scope.t(), WorkingCopy.t()) :: :ok
  def copy_joined(%Scope{active_project_id: project_id}, %WorkingCopy{label: label}) do
    tell_worker(
      project_id,
      if(is_binary(label) and String.starts_with?(label, Worker.gate_label()),
        do: :gate_copy_joined,
        else: :kick
      )
    )

    :ok
  end

  defp tell_worker(project_id, message) do
    case Registry.lookup(CodeMySpec.PromotionQueue.Registry, project_id) do
      [{pid, _}] -> GenServer.cast(pid, message)
      [] -> :ok
    end
  end

  @doc "Resume every project with candidates still open. Called at boot."
  @spec resume_all() :: :ok
  def resume_all do
    DeviceSync.resume_all()

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

  # The story named; or the issue named (`issue_id:`, the promote task's own),
  # which has to be this copy's; or else the issue assigned to the copy that is
  # waiting to be promoted (`Issues.assigned_to_copy/2`); or nothing.
  #
  # e4c9bfcd, 2026-10-05: a copy held four issues, and the one picked was not
  # the one being promoted — it had not passed QA, so every promote from the
  # copy was refused over it.
  defp subject(_scope, %{} = story, _copy, _issue_id, _head), do: {:ok, {:story, story}}

  # Unnamed, a candidate is what the copy is assigned: an accepted issue, else a
  # certified story. Nothing assigned is plain code — a refactor or UI pass
  # promotes without a story.
  defp subject(scope, nil, copy, nil, _head) do
    case {Issues.assigned_to_copy(scope, copy.id), Stories.list_certified_on_copy(scope, copy.id)} do
      {%{} = issue, _stories} -> {:ok, {:issue, issue}}
      {nil, [story | _]} -> {:ok, {:story, story}}
      {nil, []} -> {:ok, nil}
    end
  end

  defp subject(scope, nil, copy, issue_id, _head) do
    case Issues.get_issue(scope, issue_id) do
      %{status: :accepted, assigned_working_copy_id: id} = issue when id == copy.id ->
        {:ok, {:issue, issue}}

      _ ->
        {:error,
         %{
           reason:
             "issue #{issue_id} is not an accepted issue assigned to this copy, so its " <>
               "fix is not promoted from here."
         }}
    end
  end

  defp subject_attrs({:story, story}),
    do: %{subject_type: :story, subject_id: Integer.to_string(story.number)}

  defp subject_attrs({:issue, issue}), do: %{subject_type: :issue, subject_id: issue.id}
  defp subject_attrs(nil), do: %{}

  @doc """
  Release the certification of each story assigned to `working_copy_id` that
  its branch moved past, now that the copy reports `head`. The QA pass is kept
  for re-certification to carry when nothing QA exercises changed.
  """
  @spec release_moved_certifications(Scope.t(), String.t(), String.t()) :: [Stories.Story.t()]
  def release_moved_certifications(%Scope{} = scope, working_copy_id, head)
      when is_binary(working_copy_id) and is_binary(head) do
    for story <- Stories.list_certified_on_copy(scope, working_copy_id),
        story.qa_ready_commit != head,
        {:ok, released} <- [release(scope, story)],
        do: released
  end

  defp release(scope, story),
    do: Stories.release_qa_ready(scope, story, Qa.story_review_current?(scope, story.id))

  # Promotion comes after QA. With QA passing first, a promotion before it is a
  # mistake; this is the backstop that names what is missing.
  # Certified means at a commit, and promotion asks at the candidate. A stamp
  # the branch has moved past is taken back here, so the graph offers
  # `ready_for_qa` again at once instead of the queue refusing the same
  # candidate forever; the pass it had is kept for re-certification to carry
  # when nothing QA exercises changed.
  defp qa_passed(scope, {:story, story}, head) do
    cond do
      Qa.story_review_current?(scope, story.id, head) ->
        :ok

      story.qa_ready_commit not in [nil, head] ->
        {:ok, _} = release(scope, story)

        {:error,
         %{
           reason:
             "story #{story.number} is certified at #{story.qa_ready_commit}, not at this " <>
               "copy's HEAD #{head}, so it is not promoted. Its certification is released: " <>
               "complete ready_for_qa again to certify #{head}. A QA pass that still holds " <>
               "carries over when nothing QA exercises changed; otherwise QA runs again."
         }}

      true ->
        qa_verdict(false, "story #{story.number}")
    end
  end

  defp qa_passed(scope, {:issue, issue}, _head),
    do: qa_verdict(Qa.issue_qa_passed?(scope, issue.id), "the fix for issue #{issue.id}")

  defp qa_passed(_scope, nil, _head), do: :ok

  # A fix may promote itself; other accepted issues on this copy still hold
  # its work until they are resolved or their assignment is removed.
  defp assigned_issues_clear(scope, copy, subject) do
    promoting_issue_id =
      case subject do
        {:issue, issue} -> issue.id
        _ -> nil
      end

    blockers =
      scope
      |> Issues.list_by_status(:accepted)
      |> Enum.filter(
        &(&1.assigned_working_copy_id == copy.id and &1.id != promoting_issue_id and
            not qa_passed?(&1))
      )

    case blockers do
      [] ->
        :ok

      issues ->
        {:error,
         %{
           reason:
             "Issues assigned to this working copy still awaiting a fix or QA block promotion: " <>
               Enum.map_join(issues, ", ", & &1.id) <>
               ". Resolve their fixes or remove their assignments before promoting this work."
         }}
    end
  end

  # A QA-passed fix waits only on its own promotion; it does not hold the bag.
  defp qa_passed?(%{awaiting_role: :promote}), do: true
  defp qa_passed?(_issue), do: false

  defp qa_verdict(true, _what), do: :ok

  defp qa_verdict(false, what),
    do:
      {:error,
       %{
         reason:
           "#{what} has not passed QA, so it is not promoted. QA tests it on this " <>
             "copy first; promote once its QA attempt passes."
       }}

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
    environment = WorkingCopies.execution_context(%{scope | active_working_copy_id: copy.id})

    case Runner.precheck(environment, copy.root, copy.id, nil) do
      {:ok, %{head: head}} when is_binary(head) -> {:ok, head}
      {:ok, _} -> {:error, %{reason: "could not read #{copy.root}'s HEAD."}}
      {:error, _} = error -> error
    end
  end
end
