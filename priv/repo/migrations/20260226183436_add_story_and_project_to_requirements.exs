defmodule CodeMySpec.Repo.Migrations.AddStoryAndProjectToRequirements do
  use Ecto.Migration

  def change do
    alter table(:requirements) do
      add :story_id, :bigint, null: true
      add :project_id, :binary_id, null: true
      modify :component_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create index(:requirements, [:story_id])
    create index(:requirements, [:project_id])

    # Relax the existing unique constraint to a partial index
    drop unique_index(:requirements, [:component_id, :name])

    create unique_index(:requirements, [:component_id, :name],
      where: "component_id IS NOT NULL",
      name: :requirements_component_id_name_index
    )

    create unique_index(:requirements, [:story_id, :name],
      where: "story_id IS NOT NULL",
      name: :requirements_story_id_name_index
    )

    create unique_index(:requirements, [:project_id, :name],
      where: "project_id IS NOT NULL",
      name: :requirements_project_id_name_index
    )
  end
end
