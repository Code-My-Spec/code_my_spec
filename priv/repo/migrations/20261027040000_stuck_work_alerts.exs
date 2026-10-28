defmodule CodeMySpec.Repo.Migrations.StuckWorkAlerts do
  use Ecto.Migration

  def change do
    create table(:stuck_work_alerts) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :item_id, :string, null: false
      add :reported_at, :utc_datetime_usec, null: false
    end

    create unique_index(:stuck_work_alerts, [:project_id, :kind, :item_id])
  end
end
