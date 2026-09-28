defmodule CodeMySpec.Repo.Migrations.CriteriaAreNumberedAndRetired do
  @moduledoc """
  The SQLite counterpart of the Postgres `criteria_are_numbered_and_retired`.

  The backfill is a correlated count rather than a window function so the same
  statement runs on both adapters.
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
