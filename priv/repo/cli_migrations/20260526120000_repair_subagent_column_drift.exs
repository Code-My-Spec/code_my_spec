defmodule CodeMySpec.Repo.Migrations.RepairSubagentColumnDrift do
  use Ecto.Migration

  # Repairs cli-migration drift. `project_configurations.subagent_ttl_minutes`
  # (ProjectConfiguration, :integer default 10) and `sessions.subagents`
  # (Session `embeds_many :subagents`, stored as JSON text like `tasks`) reached
  # dev DBs via migrations that were never committed. A fresh cli.db built from
  # the committed migrations lacks both columns, so get_next_requirement /
  # start_task crash with "no such column" the first time they read a
  # ProjectConfiguration or load a Session.
  #
  # Guarded with PRAGMA table_info so it's a no-op on already-drifted DBs:
  # SQLite has no IF NOT EXISTS for ADD COLUMN, and a plain `add` would raise
  # "duplicate column" on every dev DB that already carries these.
  #
  # NOT touching projects.init_completed_at / setup_completed_at: those columns
  # also exist in the drifted dev DB but are referenced by no current schema or
  # code (superseded by Project.status) — orphans, correct to leave absent on
  # fresh DBs rather than resurrect dead schema.

  def up do
    add_column_if_missing(
      "project_configurations",
      "subagent_ttl_minutes",
      "INTEGER DEFAULT 10"
    )

    add_column_if_missing("sessions", "subagents", "TEXT DEFAULT '[]'")
  end

  # Irreversible by design — these columns are required by the current schema,
  # so dropping them would re-break the app. SQLite column drops are also
  # destructive table rebuilds; not worth it for a drift-repair.
  def down, do: :ok

  defp add_column_if_missing(table, column, type_sql) do
    %{rows: rows} = repo().query!("PRAGMA table_info(#{table})")
    names = Enum.map(rows, &Enum.at(&1, 1))

    unless column in names do
      execute("ALTER TABLE #{table} ADD COLUMN #{column} #{type_sql}")
    end
  end
end
