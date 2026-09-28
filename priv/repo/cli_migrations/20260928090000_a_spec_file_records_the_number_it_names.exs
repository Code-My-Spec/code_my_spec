defmodule CodeMySpec.Repo.Migrations.ASpecFileRecordsTheNumberItNames do
  @moduledoc """
  The SQLite counterpart of the Postgres `a_spec_file_records_the_number_it_names`.

  Adds the new column and drops the old one rather than renaming: a fresh
  database adds `criterion_id` earlier in this same migrator pass, and a
  rename of a column added in the same pass fails on a stale connection schema.
  """
  use Ecto.Migration

  def up do
    alter table(:files) do
      add :criterion_number, :integer
    end

    flush()

    execute("""
    UPDATE files
    SET criterion_number = CAST(json_extract(validation_errors, '$.data.criterion') AS INTEGER)
    WHERE role = 'bdd_spec' AND json_type(validation_errors, '$.data.criterion') = 'integer'
    """)

    execute("""
    UPDATE files
    SET valid = 1, validation_errors = json_object('data', json_extract(validation_errors, '$.data'))
    WHERE role = 'bdd_spec'
      AND (json_extract(validation_errors, '$.reason') LIKE 'Criterion % is not in this project%'
           OR json_extract(validation_errors, '$.reason') LIKE 'Criterion % is retired.%'
           OR json_extract(validation_errors, '$.reason') LIKE 'Criterion % is already covered by %')
    """)

    drop_if_exists index(:files, [:criterion_id])

    alter table(:files) do
      remove :criterion_id
    end

    create index(:files, [:project_id, :criterion_number])
  end

  def down do
    drop index(:files, [:project_id, :criterion_number])

    alter table(:files) do
      add :criterion_id, :bigint
      remove :criterion_number
    end

    create index(:files, [:criterion_id])
  end
end
