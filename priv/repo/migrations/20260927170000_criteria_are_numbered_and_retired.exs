defmodule CodeMySpec.Repo.Migrations.CriteriaAreNumberedAndRetired do
  @moduledoc """
  A criterion gets a number that is its name for life, and is retired rather
  than deleted.

  `id` is a per-deployment sequence: migration mints new ones, and story edits
  that deleted and recreated criteria minted new ones too. Story 1100's
  criteria went from 4999–5006 to 4073–4080 that way, and every spec naming
  them pointed at nothing.

  Numbered 1..n per project in creation order. Nothing is deleted any more, so
  one above the highest never hands out a number twice.

  Nullable, as `stories.number` was, so a schema that does not yet mint one
  cannot break inserts. The unique index is what holds.
  """
  use Ecto.Migration

  def up do
    alter table(:criteria) do
      add :number, :integer
      add :retired_at, :utc_datetime_usec
    end

    flush()

    execute("""
    UPDATE criteria SET number = (
      SELECT COUNT(*) FROM criteria earlier
      WHERE earlier.project_id = criteria.project_id
        AND (earlier.inserted_at < criteria.inserted_at
             OR (earlier.inserted_at = criteria.inserted_at AND earlier.id <= criteria.id))
    )
    """)

    create unique_index(:criteria, [:project_id, :number])
  end

  def down do
    drop index(:criteria, [:project_id, :number])

    alter table(:criteria) do
      remove :number
      remove :retired_at
    end
  end
end
