defmodule CodeMySpec.Repo.Migrations.CreateProblems do
  use Ecto.Migration

  def change do
    create table(:problems) do
      add :severity, :string, null: false
      add :source_type, :string, null: false
      add :source, :string, null: false
      add :file_path, :string, null: false
      add :line, :integer
      add :message, :text, null: false
      add :category, :string, null: false
      add :rule, :string
      add :metadata, :map
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:problems, [:project_id])
    create index(:problems, [:severity])
    create index(:problems, [:source_type])
    create index(:problems, [:file_path])
  end
end
