defmodule CodeMySpec.Repo.Migrations.CreateHarnesses do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `create_harnesses`.

  Same table, minus `gen_random_uuid()` — SQLite has no such function, so the
  application generates the id, which is what every other binary_id table in
  this set already does.

  Mirrored rather than skipped even though the channel that mints these runs
  only on the server: `files` and `problems` live in this set too, and they are
  about to reference this table. A shared Ecto schema selecting a column SQLite
  lacks is how `SocketSupervisor` crashes on :4004 boot and takes MCP with it.
  """

  def change do
    create table(:harnesses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :text
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create index(:harnesses, [:project_id])
    create index(:harnesses, [:project_id, :last_seen_at])
  end
end
