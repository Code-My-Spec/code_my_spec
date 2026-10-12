defmodule CodeMySpec.Qa.IssueQaResumes do
  @moduledoc "Audited resumption of operational partial QA; never a coding or QA verdict."
  import Ecto.Query
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Qa.{IssueQaAttempts, IssueQaResume}
  alias CodeMySpec.Repo
  alias CodeMySpec.TaskOwner

  def resume(scope, actor_id, attrs) do
    Repo.transaction(fn ->
      actor =
        Repo.one(
          from(a in Agent,
            where: a.id == ^actor_id and a.project_id == ^scope.active_project_id,
            lock: "FOR UPDATE"
          )
        )

      unless actor && actor.role == :main && is_nil(actor.off_at) && is_nil(actor.retired_at),
        do: Repo.rollback(:only_project_main)

      unless attrs[:operational_only] == true,
        do: Repo.rollback(:operational_attestation_required)

      issue =
        Repo.one(
          from(i in Issue,
            where: i.id == ^attrs[:issue_id] and i.project_id == ^scope.active_project_id,
            lock: "FOR UPDATE"
          )
        )

      unless issue && issue.status == :accepted && is_binary(issue.assigned_working_copy_id),
        do: Repo.rollback(:issue_not_assigned_and_accepted)

      unless issue.assigned_working_copy_id == attrs[:working_copy_id],
        do: Repo.rollback(:assignment_changed)

      attempt = IssueQaAttempts.latest(scope, issue.id)

      unless attempt && attempt.id == attrs[:attempt_id] && attempt.status == :partial &&
               not Enum.any?(attempt.scenarios, &(&1.status == :fail)),
             do: Repo.rollback(:latest_attempt_not_operational_partial)

      coder =
        Repo.one(
          from(a in Agent,
            where: a.id == ^attrs[:coding_agent_id] and a.project_id == ^scope.active_project_id,
            lock: "FOR UPDATE"
          )
        )

      unless coder && coder.role == :coding &&
               coder.working_copy_id == issue.assigned_working_copy_id &&
               coder.issue_id == issue.id,
             do: Repo.rollback(:coding_owner_changed)

      task = TaskOwner.find_task(coder, attrs[:coding_task_id])

      unless task && task.requirement_name == "fix_issue" && task.issue_id == issue.id &&
               task.status == :completed && not is_nil(task.completed_at) &&
               DateTime.compare(task.completed_at, attempt.submitted_at) != :gt,
             do: Repo.rollback(:completed_fix_required)

      newer_work =
        Enum.any?(TaskOwner.tasks(coder), fn other ->
          other.id != task.id && other.issue_id == issue.id &&
            other.requirement_name == "fix_issue" &&
            not is_nil(other.started_at) &&
            DateTime.compare(other.started_at, task.completed_at) == :gt
        end)

      if newer_work, do: Repo.rollback(:newer_coding_attempt_exists)
      existing = Repo.get_by(IssueQaResume, attempt_id: attempt.id)

      case existing do
        nil ->
          unless issue.awaiting_role == :coding, do: Repo.rollback(:issue_not_awaiting_coding)

          audit_attrs =
            Map.take(attrs, [
              :issue_id,
              :attempt_id,
              :working_copy_id,
              :coding_agent_id,
              :coding_task_id,
              :candidate_sha,
              :reason
            ])
            |> Map.merge(%{
              project_id: scope.active_project_id,
              authorized_by_agent_id: actor.id,
              authorized_at: DateTime.utc_now()
            })

          audit =
            case %IssueQaResume{} |> IssueQaResume.changeset(audit_attrs) |> Repo.insert() do
              {:ok, audit} -> audit
              {:error, error} -> Repo.rollback(error)
            end

          case Issues.set_awaiting_role(scope, issue, :qa) do
            {:ok, _} -> audit
            {:error, error} -> Repo.rollback(error)
          end

        audit ->
          same? =
            Enum.all?(
              [
                :issue_id,
                :working_copy_id,
                :coding_agent_id,
                :coding_task_id,
                :candidate_sha,
                :reason
              ],
              &(Map.get(audit, &1) == attrs[&1])
            )

          unless same? && issue.awaiting_role == :qa,
            do: Repo.rollback(:conflicting_or_stale_resume)

          audit
      end
    end)
  end

  def latest(scope, issue_id) do
    Repo.one(
      from(r in IssueQaResume,
        where: r.project_id == ^scope.active_project_id and r.issue_id == ^issue_id,
        order_by: [desc: r.authorized_at, desc: r.id],
        limit: 1
      )
    )
  end
end
