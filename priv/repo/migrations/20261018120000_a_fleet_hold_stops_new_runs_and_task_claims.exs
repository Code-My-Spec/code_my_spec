defmodule CodeMySpec.Repo.Migrations.AFleetHoldStopsNewRunsAndTaskClaims do
  use Ecto.Migration

  def change do
    create table(:fleet_holds, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:reason, :text, null: false)
      add(:placed_by, :string)
      add(:status, :string, null: false, default: "active")
      add(:lifted_by, :string)
      add(:lifted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:fleet_holds, [:project_id],
        where: "status = 'active'",
        name: :fleet_holds_one_active_per_project
      )
    )
  end
end
