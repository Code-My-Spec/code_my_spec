defmodule CodeMySpec.Repo.Migrations.CreateTagsAndCriteria do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:component_tags) do
      add :name, :string, null: false
      add :project_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:component_tags, [:name, :project_id])

    create_if_not_exists table(:story_tags) do
      add :tag_id, references(:component_tags, on_delete: :delete_all), null: false
      add :story_id, references(:stories, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:story_tags, [:tag_id, :story_id])
    create_if_not_exists index(:story_tags, [:story_id])

    create_if_not_exists table(:criteria) do
      add :description, :string, null: false
      add :verified, :boolean, default: false
      add :verified_at, :utc_datetime
      add :project_id, :binary_id
      add :account_id, :binary_id
      add :story_id, references(:stories, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:criteria, [:story_id])
  end
end
