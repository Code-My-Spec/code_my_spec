defmodule CodeMySpec.Repo.Migrations.EnvironmentsTimestampsToMicroseconds do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `environments_timestamps_to_microseconds`,
  and deliberately empty.

  The Postgres version widens `inserted_at`/`updated_at` to `utc_datetime_usec`
  with `modify`, which compiles to `ALTER COLUMN`. SQLite has no such
  statement, so the mirrored copy raised `ALTER COLUMN not supported by
  SQLite3` and took the whole CLI down on boot — the migrator is a supervised
  child, so a migration that raises is not a failed migration, it is an
  application that will not start.

  Nothing is lost by skipping it. SQLite is dynamically typed: a datetime is
  stored as the text it was given, and the precision comes from how Ecto casts
  on the way in and out. That is a property of the schema, which both
  deployments share, so the sub-second precision this migration exists for is
  already present here without a DDL change.

  Kept as an empty migration rather than deleted so the version numbers stay
  aligned across the two sets. A gap would leave `schema_migrations` on SQLite
  permanently behind Postgres, and the next person comparing them would have to
  work out whether something had failed.
  """

  def change do
    :ok
  end
end
