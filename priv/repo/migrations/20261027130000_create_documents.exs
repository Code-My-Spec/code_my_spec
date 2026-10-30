defmodule CodeMySpec.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :document_type, :string, null: false
      add :story_number, :integer, null: false, default: 0
      add :content, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:documents, [:project_id, :document_type, :story_number])
  end
end
