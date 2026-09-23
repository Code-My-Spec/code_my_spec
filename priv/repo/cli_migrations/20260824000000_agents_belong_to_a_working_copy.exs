defmodule CodeMySpec.Repo.Migrations.AgentsBelongToAWorkingCopy do
  @moduledoc """
  An agent belongs to a working copy by its id, not by a matching path string.

  `agents.harness_id` has been on the row since the table was created and
  nothing keyed on it. The join was `agents.working_copy == harnesses.root` —
  two reported strings compared to each other, which is the same mistake the
  hook surface stopped making when it moved to id addressing.

  Two ways it goes wrong. A copy that normalises its path differently
  (a symlink, a trailing slash, `/private/tmp` versus `/tmp`) silently forms its
  own group and the agent lands on a working copy that does not exist. And two
  harness rows can share a root — there are five such groups on this project
  today — so a path match is ambiguous exactly where the answer matters.

  `working_copy` stays. It is where the agent actually runs, which `PiConfig`
  needs to mint a config directory outside it and the conversation key needs to
  match what a lane pushes under. Same status as `harnesses.root`: reported, and
  no longer identifying.

  ## Backfill is best-effort on purpose

  Nothing here is in production. Rows whose `harness_id` names a harness that no
  longer exists are nulled rather than deleted — losing the link is recoverable,
  losing the row is not — and the rest are matched by root where that is
  unambiguous. The column stays nullable in the database and required in the
  changeset, which is how `harnesses` treats `root`: old rows keep whatever they
  have, and nothing new can be written without one.

  ## Why this is not the Postgres copy

  Two statements in the twin are Postgres-only. `UPDATE agents a SET ... FROM
  harnesses h` is not SQLite's spelling, and `modify :harness_id,
  references(...)` is an `ALTER COLUMN`, which SQLite does not have — so the
  constraint is written into a rebuilt table instead. The backfill is the same
  rule expressed as a correlated subquery.
  """

  use Ecto.Migration

  def up do
    # A dangling id would fail the constraint below. Null it first: the row is
    # still evidence that an agent ran, and which copy it ran on is the part
    # that is genuinely lost.
    execute("""
    UPDATE agents SET harness_id = NULL
    WHERE harness_id IS NOT NULL
      AND harness_id NOT IN (SELECT id FROM harnesses)
    """)

    # Where a root names exactly one harness on the same project, that is the
    # answer. Where it names several, no guess is better than another and the
    # row keeps a null.
    execute("""
    UPDATE agents
    SET harness_id = (
      SELECT h.id FROM harnesses h
      WHERE h.project_id = agents.project_id
        AND h.root = agents.working_copy
    )
    WHERE harness_id IS NULL
      AND (SELECT count(*) FROM harnesses x
           WHERE x.project_id = agents.project_id
             AND x.root = agents.working_copy) = 1
    """)

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

      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :account_id, :binary_id, null: false

      timestamps(type: :utc_datetime)
    end

    execute("""
    INSERT INTO agents (id, engine, provider, working_copy, config_dir, os_pid,
                        status, role, harness_id, project_id, account_id,
                        inserted_at, updated_at)
    SELECT id, engine, provider, working_copy, config_dir, os_pid,
           status, role, harness_id, project_id, account_id,
           inserted_at, updated_at
    FROM agents_old
    """)

    drop table(:agents_old)

    create index(:agents, [:project_id])
    create index(:agents, [:account_id])
    create index(:agents, [:working_copy])
    create index(:agents, [:project_id, :status])
    create index(:agents, [:project_id, :working_copy, :role])

    # The join the page makes on every render, and the lookup the reconcile
    # makes per reported lane.
    create index(:agents, [:harness_id, :role])
  end

  def down do
    drop index(:agents, [:harness_id, :role])
  end
end
