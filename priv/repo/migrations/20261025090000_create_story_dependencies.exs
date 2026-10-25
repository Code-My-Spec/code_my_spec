defmodule CodeMySpec.Repo.Migrations.CreateStoryDependencies do
  use Ecto.Migration

  def change do
    create table(:story_dependencies, primary_key: false) do
      add :story_id, references(:stories, on_delete: :delete_all), null: false
      add :builds_on_id, references(:stories, on_delete: :delete_all), null: false
    end

    create unique_index(:story_dependencies, [:story_id, :builds_on_id])
    create index(:story_dependencies, [:builds_on_id])

    create constraint(:story_dependencies, :story_dependencies_no_self_link,
             check: "story_id <> builds_on_id"
           )
  end
end
