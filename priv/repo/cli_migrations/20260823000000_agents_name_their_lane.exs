defmodule CodeMySpec.Repo.Migrations.AgentsNameTheirLane do
  @moduledoc """
  Which lane on the working copy this agent is.

  A working copy runs one or more agents, and until now the row could not say
  which one it was: `record_reported/2` found the copy's agent with
  `Enum.find(&(&1.working_copy == root))`, so a second lane on the same copy
  overwrote the first instead of joining it. The list claimed one agent per
  checkout because the schema could not hold two.

  `role` is what the harness already calls a lane — `CodeMySpecLocalWeb.HarnessChannel`
  joins `harness:session:<external_id>` with a role and tracks Presence under
  it, so the name is taken from the thing being described rather than invented
  here.

  Backfilled to "main" rather than left null: every existing row is the one
  lane its copy was reporting, and a null would make "which lane" unanswerable
  for rows that do have an answer. No default on the column — that lives on the
  schema, where the code that writes rows can see it.

  ## Why this is not the Postgres copy

  The Postgres twin adds the column, backfills it, then alters it to `NOT
  NULL`. SQLite has no `ALTER COLUMN`, so that third step raises
  `ALTER COLUMN not supported by SQLite3` and the whole set stops here — which
  is what stranded every CLI database for a month. The constraint is written
  into a new table instead and the backfill happens in the copy, which is the
  same shape `20260517235100_qa_invalidations_drop_users_fk` already uses.
  """

  use Ecto.Migration

  def up do
    rename table(:agents), to: table(:agents_old)

    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :engine, :string, null: false
      add :provider, :string, null: false
      add :working_copy, :string, null: false
      add :config_dir, :string
      add :os_pid, :integer
      add :status, :string, null: false
      add :role, :string, null: false
      add :harness_id, :binary_id

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    # 'main' literal rather than a backfill UPDATE: the column does not exist on
    # the old table, so there is nothing to coalesce.
    execute("""
    INSERT INTO agents (id, engine, provider, working_copy, config_dir, os_pid,
                        status, role, harness_id, project_id, account_id,
                        inserted_at, updated_at)
    SELECT id, engine, provider, working_copy, config_dir, os_pid,
           status, 'main', harness_id, project_id, account_id,
           inserted_at, updated_at
    FROM agents_old
    """)

    drop table(:agents_old)

    # Recreated because the rebuild dropped them with the old table.
    create index(:agents, [:project_id])
    create index(:agents, [:account_id])
    create index(:agents, [:working_copy])
    create index(:agents, [:project_id, :status])

    # The reconcile's lookup, which is now per lane rather than per copy.
    create index(:agents, [:project_id, :working_copy, :role])
  end

  def down do
    drop index(:agents, [:project_id, :working_copy, :role])

    alter table(:agents) do
      remove :role
    end
  end
end
