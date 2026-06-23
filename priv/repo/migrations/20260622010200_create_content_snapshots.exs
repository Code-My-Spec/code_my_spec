defmodule CodeMySpec.Repo.Migrations.CreateContentSnapshots do
  use Ecto.Migration

  def change do
    create table(:content_snapshots) do
      add :raw_content, :text
      add :processed_content, :text
      add :parse_status, :string, null: false
      add :parse_errors, :map
      add :metadata, :map

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:content_snapshots, [:project_id])
  end
end
