defmodule CodeMySpec.Repo.Migrations.IssuesGetAssignedToWorkingCopies do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      # The team currently bound to this issue, distinct from `working_copy_id`
      # (which copy raised it). Nil until `AssignIssueToWorkingCopy` sets it.
      add :assigned_working_copy_id,
          references(:working_copies, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:agents) do
      # Mirrors `story_id` (a31f1cd6) for issue-scoped work: held by every
      # team member on the copy the issue is assigned to, cleared when the
      # team is freed.
      add :issue_id, references(:issues, type: :binary_id, on_delete: :nilify_all)
      # When a team became free of its last issue with no story to fall back
      # to. Set, it holds the team visibly waiting for main's next assignment
      # instead of falling through to project-level work.
      add :team_free_at, :utc_datetime_usec
    end

    create index(:issues, [:assigned_working_copy_id])
    create index(:agents, [:issue_id])
  end
end
