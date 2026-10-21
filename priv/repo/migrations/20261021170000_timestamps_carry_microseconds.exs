defmodule CodeMySpec.Repo.Migrations.TimestampsCarryMicroseconds do
  use Ecto.Migration

  # Every timestamp to microsecond precision, as the schemas now declare: two
  # columns of different precision do not order against each other, and SQLite
  # (the desktop) compares them as text. Raising a timestamp's precision does
  # not rewrite the table.
  def up do
    execute(fn ->
      %{rows: columns} =
        repo().query!(
          """
          SELECT table_name, column_name, data_type
            FROM information_schema.columns
           WHERE table_schema = 'public'
             AND data_type LIKE 'timestamp%'
             AND datetime_precision = 0
          """,
          [], timeout: :infinity)

      for [table, column, type] <- columns do
        precise = String.replace(type, "timestamp", "timestamp(6)", global: false)

        repo().query!(
          ~s(ALTER TABLE "#{table}" ALTER COLUMN "#{column}" TYPE #{precise}),
          [],
          timeout: :infinity
        )
      end
    end)
  end

  def down, do: :ok
end
