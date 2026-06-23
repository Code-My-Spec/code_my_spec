defmodule CodeMySpec.Repo.Migrations.CreateContentImages do
  use Ecto.Migration

  def change do
    create table(:content_images) do
      add :key, :string, null: false
      add :content_hash, :string, null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:content_images, [:project_id, :key])
  end
end
