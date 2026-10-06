defmodule CodeMySpec.Repo.Migrations.AnAppRestartWithNoTeamHoldingAStoryIsProjectLevel do
  use Ecto.Migration

  # Story 1092, criterion 1998. `RestartApp` restarts a whole working copy's
  # app, not one agent, so `agent_restarts` (keyed to a single agent) cannot
  # record it. Kept separately for the same reason: a working copy can be
  # between stories, or hold none at all, and whether it did is read from
  # `agents.story_id` at report time rather than stamped here.
  def change do
    create table(:app_restarts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :working_copy_id, references(:working_copies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :reason, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:app_restarts, [:working_copy_id])
  end
end
