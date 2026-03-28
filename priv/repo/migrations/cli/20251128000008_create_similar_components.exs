defmodule CodeMySpec.Repo.Migrations.CreateSimilarComponents do
  use Ecto.Migration

  def change do
    create table(:similar_components) do
      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all),
        null: false

      add :similar_component_id, references(:components, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:similar_components, [:component_id])
    create index(:similar_components, [:similar_component_id])
    create unique_index(:similar_components, [:component_id, :similar_component_id])
  end
end
