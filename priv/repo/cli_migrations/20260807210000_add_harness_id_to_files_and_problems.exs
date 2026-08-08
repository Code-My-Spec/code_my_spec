defmodule CodeMySpec.Repo.Migrations.AddHarnessIdToFilesAndProblems do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres migration of the same name.

  Same columns and indexes — the plain Ecto DSL is adapter-agnostic. Mirrored
  because `files` and `problems` are both in this set and are queried through
  schemas shared with the server: a schema selecting a column SQLite lacks is
  how `SocketSupervisor` crashes on :4004 boot and takes MCP with it.

  Nullable here for the same reason as there, and the backfill lives in the
  application rather than in SQL precisely so this file does not have to
  generate UUIDs the way Postgres does.
  """

  def change do
    alter table(:files) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:problems) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:files, [:harness_id])
    create index(:files, [:project_id, :harness_id])
    create index(:problems, [:harness_id])
    create index(:problems, [:project_id, :harness_id])
  end
end
