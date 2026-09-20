defmodule CodeMySpec.Repo.Migrations.AddActiveStoryToWorkingCopies do
  use Ecto.Migration

  def change do
    alter table(:working_copies) do
      add :active_story_id, references(:stories, on_delete: :nilify_all)
    end

    create index(:working_copies, [:active_story_id])
  end
end
