defmodule CodeMySpec.Repo.Migrations.AddSpecPathToCriteria do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `add_spec_path_to_criteria`.

  Mirrored because the harness is where spex files actually live — it is the
  side with a disk — so it is the side that records where each one is. A field
  the shared Ecto schema selects and SQLite lacks is how `SocketSupervisor`
  crashes on boot and takes MCP with it.

  `add` rather than `modify`: `modify` compiles to ALTER COLUMN, which SQLite
  does not have, and the migrator is a supervised child — so that is not a
  failed migration but a CLI that will not start.
  """

  def change do
    alter table(:criteria) do
      add :spec_path, :text
    end
  end
end
