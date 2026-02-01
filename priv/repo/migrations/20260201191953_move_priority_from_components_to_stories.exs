defmodule CodeMySpec.Repo.Migrations.MovePriorityFromComponentsToStories do
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :priority, :integer
    end

    alter table(:components) do
      remove :priority, :integer
    end
  end
end
