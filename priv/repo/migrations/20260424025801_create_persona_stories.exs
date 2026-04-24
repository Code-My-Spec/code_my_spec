defmodule CodeMySpec.Repo.Migrations.CreatePersonaStories do
  use Ecto.Migration

  def change do
    create table(:persona_stories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :persona_id, references(:personas, type: :binary_id, on_delete: :delete_all),
        null: false
      add :story_id, references(:stories, type: :id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:persona_stories, [:story_id])
    create unique_index(:persona_stories, [:persona_id, :story_id])
  end
end
