defmodule CodeMySpec.Repo.Migrations.ASpecFileRecordsTheNumberItNames do
  @moduledoc """
  A spex file records the criterion number its `spex` call names, and nothing
  derived from it.

  `criterion_id` stored the binding itself, worked out when the file was
  scanned. A criterion retired, restored or created afterwards changed what the
  file was bound to without the file changing, so the row went stale until
  something rescanned it. The number is what the file says; which criterion it
  covers is a join, and a join cannot go stale.

  Rows a binding had marked invalid (unknown, retired or duplicate number) get
  their content verdict back; those reasons are read, not stored, from now on.
  """
  use Ecto.Migration

  def up do
    alter table(:files) do
      add :criterion_number, :integer
    end

    flush()

    execute("""
    UPDATE files
    SET criterion_number = (validation_errors->'data'->>'criterion')::integer
    WHERE role = 'bdd_spec' AND validation_errors->'data'->>'criterion' ~ '^[0-9]+$'
    """)

    execute("""
    UPDATE files
    SET valid = true, validation_errors = jsonb_build_object('data', validation_errors->'data')
    WHERE role = 'bdd_spec'
      AND (validation_errors->>'reason' LIKE 'Criterion % is not in this project%'
           OR validation_errors->>'reason' LIKE 'Criterion % is retired.%'
           OR validation_errors->>'reason' LIKE 'Criterion % is already covered by %')
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
