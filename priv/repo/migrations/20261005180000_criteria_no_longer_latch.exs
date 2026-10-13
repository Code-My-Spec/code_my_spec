defmodule CodeMySpec.Repo.Migrations.CriteriaNoLongerLatch do
  use Ecto.Migration

  # John, 2026-10-05: analysis runs only at certification and promote, so every
  # red spex blocks there and a criterion's latch has no job.
  def up do
    alter table(:criteria) do
      remove :latched_at
    end
  end

  def down do
    alter table(:criteria) do
      add :latched_at, :utc_datetime_usec
    end
  end
end
