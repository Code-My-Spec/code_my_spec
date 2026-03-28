defmodule CodeMySpec.Repo.Migrations.CreateIssues do
  use Ecto.Migration

  def change do
    create table(:issues, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :severity, :string, null: false
      add :scope, :string, null: false, default: "app"
      add :description, :text, null: false
      add :status, :string, null: false, default: "incoming"
      add :resolution, :text
      add :story_id, :integer
      add :source_path, :string
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :account_id, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:issues, [:project_id])
    create index(:issues, [:account_id])
    create index(:issues, [:status])
    create index(:issues, [:story_id])
    create unique_index(:issues, [:title, :story_id, :project_id])
  end
end
