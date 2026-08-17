defmodule CodeMySpec.Repo.Migrations.DropSessionsInteractionsColumn do
  @moduledoc """
  Drop `sessions.interactions`, the last of the interactions storage.

  `20260816000000` dropped the `interactions` and `interaction_events` tables.
  This is the same leftover one layer down and a good deal older: a `:map`
  column written by the original `create_sessions`, from before interactions
  became rows of their own. It survived the model's deletion by being a column
  rather than a table — nothing to `drop table`, and no schema field to notice
  missing.

  Nothing has read or written it since. `Session` has no such field, so
  `Utils.Data.serialize_sessions/1` naming `:interactions` in its `Map.take`
  took nothing and quietly produced a key-less export for years; that call is
  removed alongside this. 43 session rows in dev, none with a value.

  Separate from `20260816000000` rather than folded into it because that
  migration had already been applied by the time the column was found. Editing
  an applied version would have left the drop recorded but never executed —
  the failure mode this migration exists to avoid.
  """
  use Ecto.Migration

  def up do
    alter table(:sessions) do
      remove :interactions
    end
  end

  def down do
    alter table(:sessions) do
      add :interactions, :map
    end
  end
end
