defmodule CodeMySpec.Agents.IssueAssignment do
  @moduledoc """
  Which working copy's team an issue is bound to (story 1091).

  Mirrors `Assignment`'s story binding, but keyed on `Issue.assigned_working_copy_id`
  rather than a reservation: an issue is not a checkout's story, it is simply
  handed to a copy's coding and QA agents, who each hold it on their own
  `issue_id` (`Agent.issue_id`) the same way a team member holds `story_id`.

  ## Moving an issue

  `assign/4` both first-assigns an unassigned issue and moves one already
  bound elsewhere. Moving it clears the old team's `issue_id` and carries any
  open task on the issue to the new team's matching role, under the same
  task id — `AssignIssueToWorkingCopy`'s `reason` explains why to whoever
  reads the new team's task, not to this module.
  """

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Conversations
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @doc """
  Bind `issue_id` to the coding and QA team on `working_copy_id`.

  `{:error, :not_found}` for an issue or a working copy outside the scope's
  project. `{:error, :no_team}` when the destination copy has no coding or
  QA agent — there is nobody to hold the issue.
  """
  @spec assign(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Issues.Issue.t()} | {:error, term()}
  def assign(%Scope{} = scope, issue_id, working_copy_id, _opts \\ []) do
    with issue when not is_nil(issue) <- Issues.get_issue(scope, issue_id),
         :ok <- in_project(scope, working_copy_id) do
      Repo.transaction(fn -> fan_out(scope, issue, working_copy_id) end)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp in_project(%Scope{active_project_id: project_id}, copy_id) do
    case WorkingCopies.fetch(copy_id) do
      {:ok, %{project_id: ^project_id}} -> :ok
      {:ok, _other} -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  defp fan_out(scope, issue, working_copy_id) do
    new_team = lock_team(scope, working_copy_id)
    if new_team == [], do: Repo.rollback(:no_team)

    old_team = lock_team(scope, issue.assigned_working_copy_id)
    move_tasks(old_team, new_team, issue.id)
    release(old_team)
    bind(new_team, issue.id)

    case Issues.set_assigned_working_copy(scope, issue, working_copy_id) do
      {:ok, updated} -> updated
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_team(_scope, nil), do: []

  defp lock_team(scope, copy_id) do
    from(a in Agent,
      where:
        a.project_id == ^scope.active_project_id and a.account_id == ^scope.active_account_id and
          a.working_copy_id == ^copy_id and a.role in ^team_roles() and is_nil(a.retired_at),
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  defp team_roles, do: Enum.filter(RoleProfile.roles(), &Assignment.team_member?/1)

  # The open task on this issue, if any, follows its holder's role to the new
  # team — under the same id, so a caller already holding it (`list_tasks`,
  # `evaluate_task`) keeps naming the same task after the move.
  defp move_tasks(old_team, new_team, issue_id) do
    Enum.each(old_team, fn old_agent ->
      with task when not is_nil(task) <- open_issue_task(old_agent, issue_id),
           new_agent when not is_nil(new_agent) <-
             Enum.find(new_team, &(&1.role == old_agent.role)) do
        old_agent |> Agent.drop_task(task.id) |> Repo.update!()
        new_agent |> Agent.add_task(Map.from_struct(task)) |> Repo.update!()
      else
        nil -> :ok
      end
    end)
  end

  defp open_issue_task(agent, issue_id) do
    Enum.find(agent.tasks || [], &(&1.issue_id == issue_id and &1.status in [:active, :blocked]))
  end

  defp release([]), do: :ok

  defp release(old_team) do
    from(a in Agent, where: a.id in ^Enum.map(old_team, & &1.id))
    |> Repo.update_all(set: [issue_id: nil])
  end

  defp bind(new_team, issue_id) do
    from(a in Agent, where: a.id in ^Enum.map(new_team, & &1.id))
    |> Repo.update_all(set: [issue_id: issue_id, team_free_at: nil])
  end

  @doc """
  Clear `issue.id` from every agent bound to it — a passing `IssueQaAttempts.submit/2`
  calls this once the issue is resolved.

  A member left with no story to fall back to is marked `team_free_at`
  (`Agents.Work` then answers it "waiting for main assignment" instead of
  project-level work); one left with a story falls back to that normally.
  If anyone was, main is sent exactly one `:team_free` offer naming this
  copy and the issue that finished.

  A task a member still holds on the issue — the coder's `promote_issue`,
  open while its fix waited in the promotion queue — is completed: the issue
  is done, and a held task would keep the member from waiting for main.
  """
  @spec free(Scope.t(), Issues.Issue.t()) :: :ok
  def free(%Scope{} = _scope, %{assigned_working_copy_id: nil}), do: :ok

  def free(%Scope{} = scope, %{assigned_working_copy_id: copy_id, id: issue_id} = issue) do
    now = DateTime.utc_now()

    team =
      from(a in Agent,
        where: a.project_id == ^scope.active_project_id and a.issue_id == ^issue_id,
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    Enum.each(team, fn agent ->
      from(a in Agent, where: a.id == ^agent.id)
      |> Repo.update_all(set: [issue_id: nil, team_free_at: free_at(agent, now)])

      complete_held_tasks(scope, agent, issue_id)
    end)

    if Enum.any?(team, &is_nil(&1.story_id)), do: notify_main(scope, copy_id, issue)

    :ok
  end

  defp complete_held_tasks(scope, agent, issue_id) do
    for %{issue_id: ^issue_id, status: status, id: task_id} <- TaskOwner.tasks(agent),
        status in [:active, :prepared, :blocked] do
      {:ok, _} = TaskOwner.complete_task(scope, Repo.get!(Agent, agent.id), task_id, :completed)
    end
  end

  defp free_at(%Agent{story_id: nil}, now), do: now
  defp free_at(%Agent{}, _now), do: nil

  defp notify_main(scope, copy_id, issue) do
    case AgentsRepository.list_running_main(scope) do
      [main | _] ->
        text = team_free_message(copy_id, issue)

        main
        |> Conversations.record_sent_to_agent(text)
        |> Offers.record(main, :team_free, {"copy", copy_id})

        :ok

      [] ->
        :ok
    end
  end

  defp team_free_message(copy_id, issue) do
    "Working copy #{copy_id}'s team is free: issue #{issue.id} (\"#{issue.title}\") is " <>
      "resolved and nothing else is assigned to it. Assign it another issue with " <>
      "assign_issue_to_working_copy, or a story with assign_team."
  end
end
