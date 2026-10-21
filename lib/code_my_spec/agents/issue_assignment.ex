defmodule CodeMySpec.Agents.IssueAssignment do
  @moduledoc """
  Owns the issues assigned to a working copy's coding and QA team (story 1091).

  `Issue.assigned_working_copy_id` is bag membership; the teammates' `issue_id`
  is a shared priority. The first assignment establishes that priority and its
  exclusive issue-work assignment. Additional assignments preserve the priority.
  Coding and QA select their eligible work independently from the bag.

  Moving an issue transfers its open tasks to the matching role. Removing or
  completing the priority selects remaining work; only completing the final
  issue with no story remaining sends main a team-free offer.
  """

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Assignment
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Issues
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @doc """
  Add or move an accepted issue to the team's bag, or remove it with a nil copy.
  Removal refuses open tasks; moving preserves them. A bag may not mix issues
  from different story assignments. Returns `:not_found` outside the project,
  or `:no_team` when the destination has no coding or QA agent.
  """
  @spec assign(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Issues.Issue.t()} | {:error, term()}
  def assign(%Scope{} = scope, issue_id, working_copy_id, opts \\ []) do
    with issue when not is_nil(issue) <- Issues.get_issue(scope, issue_id),
         :ok <- in_project(scope, working_copy_id) do
      result =
        case {working_copy_id, Keyword.get(opts, :rework, false)} do
          {nil, true} ->
            {:error, "Corrections require an assigned working copy."}

          {nil, false} ->
            transaction(scope, issue.id, &clear_binding(scope, &1))

          {copy_id, true} ->
            transaction(scope, issue.id, &request_corrections(scope, &1, copy_id, opts))

          {copy_id, false} ->
            transaction(scope, issue.id, &fan_out(scope, &1, copy_id))
        end

      announce_assignment(scope, result)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp announce_assignment(scope, {:ok, _issue} = result) do
    WorkingCopies.announce_selection(scope)
    result
  end

  defp announce_assignment(_scope, error), do: error

  @doc "Open issues owned by this working copy, independently of its active priority."
  def bag(%Scope{active_project_id: project_id}, copy_id) when is_binary(copy_id) do
    Repo.all(
      from i in Issues.Issue,
        where:
          i.project_id == ^project_id and i.assigned_working_copy_id == ^copy_id and
            i.status == :accepted,
        order_by: [asc: i.inserted_at, asc: i.id]
    )
  end

  def bag(_scope, _copy_id), do: []

  @doc "Clear the issue bag when the locked team switches to story work."
  def clear_for_story(scope, copy_id) do
    team = lock_team(scope, copy_id)

    issues =
      Repo.all(
        from i in Issues.Issue,
          where:
            i.project_id == ^scope.active_project_id and i.assigned_working_copy_id == ^copy_id
      )

    for agent <- team,
        task <- TaskOwner.tasks(agent),
        not is_nil(task.issue_id),
        task.status in [:active, :prepared, :blocked] do
      {:ok, _} = TaskOwner.complete_task(scope, agent, task.id, :cancelled)
    end

    Enum.each(issues, fn issue ->
      {:ok, _} = Issues.set_assigned_working_copy(scope, issue, nil)
    end)

    from(a in Agent, where: a.id in ^Enum.map(team, & &1.id))
    |> Repo.update_all(set: [issue_id: nil])
  end

  @doc "Prioritize an issue already in the team's bag; never changes bag ownership."
  def prioritize(scope, copy_id, issue_id) do
    with :ok <- in_project(scope, copy_id),
         issue when not is_nil(issue) <- Issues.get_issue(scope, issue_id) do
      transaction(scope, issue.id, &prioritize_locked(scope, copy_id, &1))
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp prioritize_locked(scope, copy_id, issue) do
    unless issue.assigned_working_copy_id == copy_id and issue.status == :accepted,
      do: Repo.rollback("The active issue must be an open issue in this working copy's bag.")

    team = lock_team(scope, copy_id)
    if team == [], do: Repo.rollback(:no_team)
    bind(team, issue)
    issue
  end

  # Serialize bag mutations within the project, including concurrent moves and
  # final completions. Reload after locking, never route from a stale owner.
  defp transaction(scope, issue_id, fun) do
    Repo.transaction(fn ->
      Repo.one!(
        from p in CodeMySpec.Projects.Project,
          where: p.id == ^scope.active_project_id,
          select: p.id,
          lock: "FOR UPDATE"
      )

      issue =
        Repo.one!(
          from i in Issues.Issue,
            where: i.id == ^issue_id and i.project_id == ^scope.active_project_id
        )

      fun.(issue)
    end)
  end

  defp request_corrections(scope, issue, copy_id, opts) do
    team = lock_team(scope, copy_id)
    if team == [], do: Repo.rollback(:no_team)

    issue = Repo.one!(from(i in Issues.Issue, where: i.id == ^issue.id, lock: "FOR UPDATE"))
    reason = Keyword.get(opts, :reason)

    unless is_binary(reason) and String.trim(reason) != "",
      do: Repo.rollback("A correction request requires a reason.")

    unless issue.status == :accepted and issue.awaiting_role == :qa and
             issue.assigned_working_copy_id == copy_id,
           do:
             Repo.rollback("Corrections require an accepted issue awaiting QA on the same copy.")

    if Enum.any?(team, &(not is_nil(open_issue_task(&1, issue.id)))),
      do:
        Repo.rollback(
          "Finish or disposition the issue's open task before requesting corrections."
        )

    description =
      issue.description <> "\n\nCorrection requested by main:\n" <> String.trim(reason)

    with {:ok, noted} <- Issues.update_issue(scope, issue, %{description: description}),
         {:ok, updated} <- Issues.set_awaiting_role(scope, noted, :coding) do
      bind(team, updated)
      updated
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  # Frees the team the issue was bound to and unsets the field. A no-op on an
  # unbound issue, so a caller can clear without first checking.
  defp clear_binding(_scope, %{assigned_working_copy_id: nil} = issue), do: issue

  defp clear_binding(scope, issue) do
    old_team = lock_team(scope, issue.assigned_working_copy_id)

    if Enum.any?(old_team, &(not is_nil(open_issue_task(&1, issue.id)))),
      do: Repo.rollback("Disposition the issue's open tasks before unassigning it.")

    case Issues.set_assigned_working_copy(scope, issue, nil) do
      {:ok, cleared} ->
        release_issue(old_team, issue.id)
        focus_remaining(scope, issue.assigned_working_copy_id)
        cleared

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp in_project(_scope, nil), do: :ok

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

    existing = bag(scope, working_copy_id) |> Enum.reject(&(&1.id == issue.id))
    validate_bag(issue, existing)

    Assignment.clear_for_issues(scope, working_copy_id)
    new_team = lock_team(scope, working_copy_id)
    old_team = lock_team(scope, issue.assigned_working_copy_id)
    move_tasks(old_team, new_team, issue.id)
    if issue.assigned_working_copy_id != working_copy_id, do: release_issue(old_team, issue.id)

    case Issues.set_assigned_working_copy(scope, issue, working_copy_id) do
      {:ok, updated} ->
        # First assignment establishes focus. Further assignments only grow
        # the bag, leaving the current issue priority intact.
        if existing == [] or Enum.all?(new_team, &is_nil(&1.issue_id)),
          do: bind(new_team, updated)

        if issue.assigned_working_copy_id != working_copy_id,
          do: focus_remaining(scope, issue.assigned_working_copy_id)

        updated

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp validate_bag(issue, existing) do
    unless issue.status == :accepted, do: Repo.rollback("Only accepted issues can be assigned.")

    if Enum.any?(existing, &(&1.story_id != issue.story_id)),
      do: Repo.rollback("A project issue bag cannot mix issues from different story assignments.")
  end

  defp focus_remaining(_scope, nil), do: :ok

  defp focus_remaining(scope, copy_id) do
    team = lock_team(scope, copy_id)
    remaining = bag(scope, copy_id)
    ids = MapSet.new(remaining, & &1.id)

    cond do
      remaining == [] -> :ok
      Enum.all?(team, &MapSet.member?(ids, &1.issue_id)) -> :ok
      true -> bind(team, hd(remaining))
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
             Enum.find(new_team, &(&1.role == old_agent.role and &1.id != old_agent.id)) do
        old_agent |> Agent.drop_task(task.id) |> Repo.update!()
        new_agent |> Agent.add_task(Map.from_struct(task)) |> Repo.update!()
      else
        nil -> :ok
      end
    end)
  end

  defp open_issue_task(agent, issue_id) do
    Enum.find(
      agent.tasks || [],
      &(&1.issue_id == issue_id and &1.status in [:active, :prepared, :blocked])
    )
  end

  defp release_issue([], _issue_id), do: :ok

  defp release_issue(old_team, issue_id) do
    from(a in Agent, where: a.id in ^Enum.map(old_team, & &1.id) and a.issue_id == ^issue_id)
    |> Repo.update_all(set: [issue_id: nil])
  end

  defp bind(new_team, issue) do
    ids = Enum.map(new_team, & &1.id)

    from(a in Agent, where: a.id in ^ids)
    |> Repo.update_all(set: [issue_id: issue.id, story_id: nil, team_free_at: nil])

    # Work offered under the old assignment is not this team's to take any more.
    Offers.supersede_work(ids)
  end

  @doc """
  Release a finished issue and complete its held tasks. Remaining bag members
  stay assigned; an exhausted project issue team waits for main and sends one
  team-free offer. Repeated completion is a no-op.
  """
  @spec free(Scope.t(), Issues.Issue.t()) :: :ok
  def free(%Scope{} = _scope, %{assigned_working_copy_id: nil}), do: :ok

  def free(%Scope{} = scope, %{id: issue_id}) do
    case transaction(scope, issue_id, &finish_binding(scope, &1)) do
      {:ok, {:notify, copy_id, issue}} ->
        CodeMySpec.Agents.notify_main(scope, :team_free, team_free_message(copy_id, issue),
          offer: {:team_free, {"copy", copy_id}}
        )

      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        raise "Could not release issue assignment: #{inspect(reason)}"
    end
  end

  defp finish_binding(_scope, %{assigned_working_copy_id: nil}), do: :ok

  defp finish_binding(scope, %{assigned_working_copy_id: copy_id} = issue) do
    team = lock_team(scope, copy_id)
    {:ok, _} = Issues.set_assigned_working_copy(scope, issue, nil)
    release_issue(team, issue.id)
    Enum.each(team, &complete_held_tasks(scope, &1, issue.id))

    if bag(scope, copy_id) == [] do
      free_finished_team(scope, team, copy_id, issue)
    else
      focus_remaining(scope, copy_id)
      :ok
    end
  end

  defp free_finished_team(_scope, team, copy_id, issue) do
    if team != [] and Enum.all?(team, &is_nil(&1.story_id)) do
      from(a in Agent, where: a.id in ^Enum.map(team, & &1.id))
      |> Repo.update_all(set: [team_free_at: DateTime.utc_now()])

      {:notify, copy_id, issue}
    else
      :ok
    end
  end

  defp complete_held_tasks(scope, agent, issue_id) do
    for %{issue_id: ^issue_id, status: status, id: task_id} <- TaskOwner.tasks(agent),
        status in [:active, :prepared, :blocked] do
      {:ok, _} = TaskOwner.complete_task(scope, Repo.get!(Agent, agent.id), task_id, :completed)
    end
  end

  # Same notice, issue half of the choice — see the comment on
  # `Agents.Assignment.team_free_message/2` (issue e21ab16c).
  defp team_free_message(copy_id, issue) do
    "Working copy #{copy_id}'s team is free: issue #{issue.id} (\"#{issue.title}\") is " <>
      "resolved and nothing else is assigned to it. Assign it another issue with " <>
      "assign_issue_to_working_copy, or a story with set_active_story."
  end
end
