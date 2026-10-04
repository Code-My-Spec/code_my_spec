defmodule CodeMySpec.Repo.Migrations.PersistTelemetryHealthChecks do
  use Ecto.Migration

  def change do
    create table(:telemetry_health_checks, primary_key: false) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :environment, :string, null: false, primary_key: true
      add :reachable, :boolean, null: false
      add :reads, :string, null: false
      add :writes, :string, null: false
      add :checked_at, :utc_datetime_usec, null: false
    end
  end
end
