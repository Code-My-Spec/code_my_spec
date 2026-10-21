defmodule CodeMySpec.Repo.SqliteMigrations.TimestampsCarryMicroseconds do
  use Ecto.Migration

  # SQLite keeps timestamps as text at whatever precision is written; the
  # schemas now write microseconds. Nothing to change in the table.
  def change, do: :ok
end
