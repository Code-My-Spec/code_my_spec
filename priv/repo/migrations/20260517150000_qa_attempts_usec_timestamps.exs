defmodule CodeMySpec.Repo.Migrations.QaAttemptsUsecTimestamps do
  use Ecto.Migration

  # Widens all timestamptz columns on qa_attempts / qa_invalidations
  # from second precision (the Ecto `:utc_datetime` default) to
  # microsecond precision. The ordering in `Qa.QaAttempts.list/2`
  # relies on microsecond-precision `inserted_at` to disambiguate
  # rapid in-process submissions.

  def change do
    alter table(:qa_attempts) do
      modify :submitted_at, :utc_datetime_usec, null: false, from: {:utc_datetime, null: false}
      modify :inserted_at, :utc_datetime_usec, null: false, from: {:utc_datetime, null: false}
      modify :updated_at, :utc_datetime_usec, null: false, from: {:utc_datetime, null: false}
    end

    alter table(:qa_invalidations) do
      modify :invalidated_at, :utc_datetime_usec, null: false,
        from: {:utc_datetime, null: false}

      modify :inserted_at, :utc_datetime_usec, null: false, from: {:utc_datetime, null: false}
      modify :updated_at, :utc_datetime_usec, null: false, from: {:utc_datetime, null: false}
    end
  end
end
