defmodule CodeMySpec.Repo.Migrations.IssuesTrackWhichRoleTheyAwait do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      # Whose turn it is on an assigned issue (story 1091): the coder's until
      # it submits a fix, QA's until it submits a non-passing attempt. Nil
      # once unassigned or resolved. Read by `Agents.IssueWork` instead of
      # `Agents` depending on `Qa` (which already depends on `Agents`).
      add :awaiting_role, :string
    end
  end
end
