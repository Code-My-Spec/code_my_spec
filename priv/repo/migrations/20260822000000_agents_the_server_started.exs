defmodule CodeMySpec.Repo.Migrations.AgentsTheServerStarted do
  @moduledoc """
  One row per coding agent CodeMySpec started.

  No column defaults here — defaults belong on the schema, where they are
  visible to the code that reads them rather than only to the database.

  `os_pid` is nullable and stays that way: it is unknown between the row being
  written and the harness answering, and it is never set for an agent that
  failed to start. That is a different state from one that started and exited,
  and collapsing them would make "did it ever run" unanswerable.
  """

  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :engine, :string, null: false
      add :provider, :string, null: false
      add :working_copy, :text, null: false
      add :config_dir, :text
      add :os_pid, :integer
      add :status, :string, null: false
      add :harness_id, :binary_id

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:agents, [:project_id])
    create index(:agents, [:account_id])
    create index(:agents, [:working_copy])

    # The listing surface asks "what is running", which is a status query per
    # project every time it is asked.
    create index(:agents, [:project_id, :status])
  end
end
