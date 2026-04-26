defmodule CodeMySpec.Repo.Migrations.CreateBddRules do
  use Ecto.Migration

  def change do
    create table(:bdd_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # CLI doesn't have an accounts table; project_id mirrors the loose
      # binary_id convention used by stories/persona_stories migrations.
      add :account_id, :binary_id, null: false
      add :project_id, :binary_id, null: false

      add :story_id, references(:stories, type: :id, on_delete: :delete_all), null: false

      add :statement, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:bdd_rules, [:account_id])
    create index(:bdd_rules, [:project_id])
    create index(:bdd_rules, [:story_id])
  end
end
