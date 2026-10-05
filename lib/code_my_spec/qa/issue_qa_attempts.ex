defmodule CodeMySpec.Qa.IssueQaAttempts do
  @moduledoc """
  Domain functions for the QA attempt lifecycle on an issue (story 1091).

  An issue resolves only when its fix has landed on main and its QA has
  passed (promote-queue, 2026-10-04). A pass on a fix not yet landed sends the
  coder to promote it (`awaiting_role: :promote`); the landing
  (`fix_landed/3`) then resolves the issue and frees its team (`Agents.Events`
  answers the `:issue_passed` event). There is no `qa_complete` graph node to
  satisfy, because an issue is not in the requirement graph.
  `Agents.IssueWork` reads this store's `latest/2` to decide whose turn it is.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Issues
  alias CodeMySpec.Qa.IssueQaAttempt
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

  @doc """
  Submit a QA outcome for an issue, as the agent testing it.

  Required params: `:issue_id`, `:task_id`, `:status`, `:scenarios`.
  Optional: `:issue_ids`.

  A pass completes `owner`'s task and hands the coder the promotion — or, if
  the fix already landed, resolves the issue and frees the team. Anything else
  just completes the task — the issue stays open and bound, and the coder is
  offered it again (`Agents.IssueWork`, from the fresh non-pass attempt
  outranking the fix it tested).

  Returns `{:ok, attempt}` or `{:error, changeset | atom}`.
  """
  @spec submit(Scope.t(), Agent.t(), map()) ::
          {:ok, IssueQaAttempt.t()} | {:error, Ecto.Changeset.t() | atom()}
  def submit(%Scope{} = scope, %Agent{} = owner, params) do
    with :ok <- validate_findings_path(params) do
      Repo.transaction(fn ->
        case insert_attempt(build_attrs(owner, params)) do
          {:ok, attempt} -> handle_outcome(scope, owner, attempt)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp handle_outcome(scope, owner, %{status: :pass} = attempt) do
    with issue when not is_nil(issue) <- Issues.get_issue(scope, attempt.issue_id),
         {:ok, _} <- TaskOwner.complete_task(scope, owner, attempt.task_id, :completed),
         :ok <- passed(scope, issue, "Verified by issue QA attempt #{attempt.id}.") do
      attempt
    else
      nil -> Repo.rollback(:issue_not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp handle_outcome(scope, owner, attempt) do
    with {:ok, _} <- TaskOwner.complete_task(scope, owner, attempt.task_id, :completed),
         :ok <- send_back_to_coder(scope, attempt.issue_id) do
      attempt
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Landed already: resolved. Not yet: the coder's turn to promote it.
  defp passed(scope, %{landed_commit: commit} = issue, resolution) when is_binary(commit),
    do: resolve(scope, issue, resolution)

  defp passed(scope, issue, _resolution) do
    with {:ok, _} <- Issues.set_awaiting_role(scope, issue, :promote), do: :ok
  end

  defp resolve(scope, issue, resolution) do
    with {:ok, resolved} <- Issues.resolve_issue(scope, issue, resolution) do
      # Agents frees the issue's team (`Agents.Events`); Qa sits below Agents.
      :telemetry.execute([:code_my_spec, :qa, :issue_passed], %{}, %{
        scope: scope,
        issue: resolved
      })

      :ok
    end
  end

  @doc """
  An issue's fix landed on main at `commit`, through the promotion queue.

  Records it, then resolves the issue and frees its team if its latest QA
  attempt passed; otherwise it is QA's turn on the landed fix.
  """
  @spec fix_landed(Scope.t(), Ecto.UUID.t(), String.t()) :: :ok | {:error, term()}
  def fix_landed(%Scope{} = scope, issue_id, commit) do
    with %{} = issue <- Issues.get_issue(scope, issue_id) || {:error, :issue_not_found},
         {:ok, issue} <- Issues.record_fix_landed(scope, issue, commit) do
      after_landing(scope, issue, passed?(scope, issue.id), commit)
    end
  end

  defp after_landing(scope, issue, true, commit),
    do: resolve(scope, issue, "Fix landed on main at #{String.slice(commit, 0, 12)}; QA passed.")

  defp after_landing(scope, issue, false, _commit) do
    with {:ok, _} <- Issues.set_awaiting_role(scope, issue, :qa), do: :ok
  end

  @doc "Whether the issue's latest QA attempt is a pass."
  @spec passed?(Scope.t(), Ecto.UUID.t()) :: boolean()
  def passed?(%Scope{} = scope, issue_id), do: match?(%{status: :pass}, latest(scope, issue_id))

  # A non-passing attempt is QA's turn finishing, same as a passing one —
  # it just hands the issue back to the coder instead of resolving it.
  defp send_back_to_coder(scope, issue_id) do
    case Issues.get_issue(scope, issue_id) do
      nil -> {:error, :issue_not_found}
      issue -> with {:ok, _} <- Issues.set_awaiting_role(scope, issue, :coding), do: :ok
    end
  end

  # Same discipline as the story contract (`QaAttempts.validate_findings_path/1`):
  # a non-pass result with nothing filed disappears the moment the session ends.
  defp validate_findings_path(params) do
    status = MapAccess.get(params, :status)
    issue_ids = MapAccess.get(params, :issue_ids, [])

    cond do
      status in [:pass, "pass"] -> :ok
      issue_ids != [] -> :ok
      true -> {:error, :fail_requires_issue_ids}
    end
  end

  defp build_attrs(owner, params) do
    %{
      issue_id: MapAccess.get(params, :issue_id),
      status: MapAccess.get(params, :status),
      scenarios: MapAccess.get(params, :scenarios, []),
      issue_ids: MapAccess.get(params, :issue_ids, []),
      agent_id: owner.id,
      task_id: MapAccess.get(params, :task_id),
      submitted_at: DateTime.utc_now()
    }
  end

  defp insert_attempt(attrs) do
    %IssueQaAttempt{}
    |> IssueQaAttempt.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The most recent QA attempt on this issue, or nil.

  Used by `Agents.IssueWork` to decide whose turn it is: a non-passing
  attempt more recent than the coder's last completed fix sends the fix
  back to them.
  """
  @spec latest(Scope.t(), Ecto.UUID.t()) :: IssueQaAttempt.t() | nil
  def latest(%Scope{active_project_id: nil}, _issue_id), do: nil

  def latest(%Scope{} = scope, issue_id) do
    IssueQaAttempt
    |> where([a], a.issue_id == ^issue_id)
    |> by_project(scope)
    |> order_by([a], desc: a.submitted_at, desc: a.id)
    |> limit(1)
    |> Repo.one()
  end

  defp by_project(query, %Scope{active_project_id: project_id}) do
    join(query, :inner, [a], i in assoc(a, :issue), on: i.project_id == ^project_id)
  end
end
