defmodule CodeMySpec.Qa.IssueQaAttempts do
  @moduledoc """
  Domain functions for the QA attempt lifecycle on an issue (story 1091).

  A pass resolves the issue and frees its team (`Agents.free_issue_team/2`)
  directly — there is no `qa_complete` graph node to satisfy, because an
  issue is not in the requirement graph. `Agents.IssueWork` reads this
  store's `latest/2` to decide whose turn it is.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Agents
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

  A pass resolves the issue, completes `owner`'s task, and frees the team
  that was bound to it. Anything else just completes the task — the issue
  stays open and bound, and the coder is offered it again
  (`Agents.IssueWork`, from the fresh non-pass attempt outranking the fix
  it tested).

  Returns `{:ok, attempt}` or `{:error, changeset | atom}`.
  """
  @spec submit(Scope.t(), Agent.t(), map()) ::
          {:ok, IssueQaAttempt.t()} | {:error, Ecto.Changeset.t() | atom()}
  def submit(%Scope{} = scope, %Agent{} = owner, params) do
    with :ok <- validate_findings_path(params) do
      Repo.transaction(fn ->
        with {:ok, attempt} <- insert_attempt(build_attrs(owner, params)) do
          handle_outcome(scope, owner, attempt)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp handle_outcome(scope, owner, %{status: :pass} = attempt) do
    with issue when not is_nil(issue) <- Issues.get_issue(scope, attempt.issue_id),
         {:ok, resolved} <-
           Issues.resolve_issue(scope, issue, "Verified by issue QA attempt #{attempt.id}."),
         {:ok, _} <- TaskOwner.complete_task(scope, owner, attempt.task_id, :completed),
         :ok <- Agents.free_issue_team(scope, resolved) do
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
