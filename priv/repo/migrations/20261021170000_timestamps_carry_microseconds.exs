defmodule CodeMySpec.Repo.Migrations.TimestampsCarryMicroseconds do
  use Ecto.Migration

  # Every timestamp to microsecond precision, as the schemas now declare: two
  # columns of different precision do not order against each other, and SQLite
  # (the desktop) compares them as text. Raising a timestamp's precision does
  # not rewrite the table. One statement, in the migration's own transaction.
  #
  # Not `schema_migrations`: Ecto holds a lock on it from another connection
  # while migrating, so altering it waits on the migrator itself.
  def up do
    execute("""
    DO $$
    DECLARE c record;
    BEGIN
      FOR c IN
        SELECT table_name, column_name, data_type
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name <> 'schema_migrations'
           AND data_type LIKE 'timestamp%'
           AND datetime_precision = 0
      LOOP
        EXECUTE format(
          'ALTER TABLE %I ALTER COLUMN %I TYPE %s',
          c.table_name, c.column_name, replace(c.data_type, 'timestamp', 'timestamp(6)')
        );
      END LOOP;
    END $$;
    """)
  end

  def down, do: :ok
end
