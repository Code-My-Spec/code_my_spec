defmodule CodeMySpec.Agents.IssueAssignment do
  @moduledoc """
  Which working copy's team an issue is bound to (story 1091).

  Mirrors `Assignment`'s story binding, but keyed on `Issue.assigned_working_copy_id`
  rather than a reservation. Both teammates take the issue on `issue_id` and
  its story on `story_id`. An issue without a story clears any prior story
  binding; unrelated story work must not survive implicitly.

  ## Moving an issue

  `assign/4` both first-assigns an unassigned issue and moves one already
  bound elsewhere. Moving it clears the old team's `issue_id` and carries any
  open task on the issue to the new team's matching role, under the same
  task id — `AssignIssueToWorkingCopy`'s `reason` explains why to whoever
  reads the new team's task, not to this module.
  """

  import Ecto.Query

  require Logger

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
  Bind `issue_id` to the coding and QA team on `working_copy_id`, or clear the
  binding by passing `nil`.

  `{:error, :not_found}` for an issue or a working copy outside the scope's
  project. `{:error, :no_team}` when the destination copy has no coding or
  QA agent — there is nobody to hold the issue.

  `nil` (91863fd2) is "clear the binding" — the inverse this had none of. A
  bind was one-way: `assign_issue_to_working_copy` refused a nil copy, and no
  other reachable tool named unbinding, so a mistaken or stale binding could
  not be reversed by anyone. Reversing a routing decision is ordinary, and
  every other routing step here is reversible.

  Clearing releases whichever team holds the issue and sets the field to nil.
  It is a no-op, not an error, on an issue that is already unbound.
  """
  @spec assign(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Issues.Issue.t()} | {:error, term()}
  def assign(%Scope{} = scope, issue_id, working_copy_id, opts \\ []) do
    with issue when not is_nil(issue) <- Issues.get_issue(scope, issue_id),
         :ok <- in_project(scope, working_copy_id) do
      case {working_copy_id, Keyword.get(opts, :rework, false)} do
        {nil, true} ->
          {:error, "Corrections require an assigned working copy."}

        {nil, false} ->
          Repo.transaction(fn -> clear_binding(scope, issue) end)

        {copy_id, true} ->
          Repo.transaction(fn -> request_corrections(scope, issue, copy_id, opts) end)

        {copy_id, false} ->
          Repo.transaction(fn -> fan_out(scope, issue, copy_id) end)
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
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
    release(old_team)

    case Issues.set_assigned_working_copy(scope, issue, nil) do
      {:ok, cleared} -> cleared
      {:error, reason} -> Repo.rollback(reason)
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

    old_team = lock_team(scope, issue.assigned_working_copy_id)
    move_tasks(old_team, new_team, issue.id)
    release(old_team)
    bind(new_team, issue)

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

  defp bind(new_team, issue) do
    from(a in Agent, where: a.id in ^Enum.map(new_team, & &1.id))
    |> Repo.update_all(set: [issue_id: issue.id, story_id: issue.story_id, team_free_at: nil])
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

    # 91863fd2: the binding is cleared here too. It used to outlive the issue —
    # the team was freed but `assigned_working_copy_id` stayed set, so the field
    # stopped meaning "the copy working this" and became "the last copy that
    # ever did", which a later reader cannot tell from an active binding.
    #
    # `free/2` returns :ok by contract and its caller (a passing QA submission)
    # has already resolved the issue, so a failure here cannot undo that. It is
    # logged rather than swallowed: a stale binding is a smaller problem than a
    # silent one.
    case Issues.set_assigned_working_copy(scope, issue, nil) do
      {:ok, _cleared} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[IssueAssignment.free] issue #{issue_id} resolved but its " <>
            "#{copy_id} binding could not be cleared: #{inspect(reason)}"
        )

        :ok
    end

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

  # Same notice, issue half of the choice — see the comment on
  # `Agents.Assignment.team_free_message/2` (issue e21ab16c).
  defp team_free_message(copy_id, issue) do
    "Working copy #{copy_id}'s team is free: issue #{issue.id} (\"#{issue.title}\") is " <>
      "resolved and nothing else is assigned to it. Assign it another issue with " <>
      "assign_issue_to_working_copy, or a story with set_active_story."
  end
end
