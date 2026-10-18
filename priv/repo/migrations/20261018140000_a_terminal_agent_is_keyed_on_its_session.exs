defmodule CodeMySpec.Repo.Migrations.ATerminalAgentIsKeyedOnItsSession do
  use Ecto.Migration

  # Story 1122: a terminal Claude Code session is an agent, found again by
  # Claude Code's own session id when it resumes.
  def change do
    alter table(:agents) do
      add(:engine_session_id, :string)
    end

    create(
      unique_index(:agents, [:project_id, :engine_session_id],
        where: "engine_session_id IS NOT NULL"
      )
    )
  end
end
