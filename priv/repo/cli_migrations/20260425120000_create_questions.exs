defmodule CodeMySpec.Repo.Migrations.CreateQuestions do
  use Ecto.Migration

  def change do
    create table(:questions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # CLI doesn't have an accounts table; account_id and project_id mirror
      # the loose binary_id convention used by the bdd_rules migration.
      add :account_id, :binary_id, null: false
      add :project_id, :binary_id, null: false

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
