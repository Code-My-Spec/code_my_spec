defmodule CodeMySpec.Repo.Migrations.AddComponentIdToProblems do
  use Ecto.Migration

  def change do
    alter table(:problems) do
      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all)
    end

    create index(:problems, [:component_id])
    create index(:problems, [:component_id, :source])
  end
end
