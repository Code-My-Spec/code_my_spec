defmodule CodeMySpec.Repo.Migrations.SimplifyComponentAnalysisTracking do
  use Ecto.Migration

  def change do
    # Clear old JSON map data before changing column type.
    # SQLite's ALTER TABLE doesn't truly drop/recreate columns,
    # so old JSON strings would crash Ecto's :utc_datetime loader.
    execute("UPDATE components SET last_analyzed_at = NULL", "SELECT 1")

    alter table(:components) do
      remove :last_analyzed_at, :map, default: %{}
      add :last_analyzed_at, :utc_datetime
    end
  end
end
