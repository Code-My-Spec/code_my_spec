defmodule CodeMySpec.Repo.Migrations.MainNamesItsWorkingCopyPerCall do
  use Ecto.Migration

  # Main names a working copy on each read/write/edit/bash (issue e377de11);
  # nothing holds an attachment any more.
  def up do
    drop table(:agent_working_copy_attachments)
  end

  def down do
    create table(:agent_working_copy_attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :working_copy_id, references(:working_copies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_working_copy_attachments, [:agent_id, :working_copy_id])
    create index(:agent_working_copy_attachments, [:working_copy_id])
    create index(:agent_working_copy_attachments, [:project_id])
  end
end
