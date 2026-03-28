defmodule CodeMySpec.Repo.Migrations.AddStoryTaskUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:tasks, [:story_id, :requirement_name],
             where: "story_id IS NOT NULL AND component_id IS NULL"
           )
  end
end
