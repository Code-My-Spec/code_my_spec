defmodule CodeMySpec.Repo.Migrations.CreateQuestions do
  use Ecto.Migration

  def change do
    create table(:questions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :story_id, references(:stories, type: :id, on_delete: :delete_all), null: false

      add :text, :text, null: false
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime)
    end

    create index(:questions, [:account_id])
    create index(:questions, [:project_id])
    create index(:questions, [:story_id])
    create index(:questions, [:story_id, :status])
  end
end
