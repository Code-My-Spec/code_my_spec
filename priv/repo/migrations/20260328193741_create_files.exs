defmodule CodeMySpec.Repo.Migrations.CreateFiles do
  use Ecto.Migration

  def change do
    create_query =
      "CREATE TYPE file_role AS ENUM ('spec', 'implementation', 'test', 'rule', 'json', 'review', 'bdd_spec', 'qa_brief', 'qa_result', 'config')"

    drop_query = "DROP TYPE file_role"
    execute(create_query, drop_query)

    create table(:files, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :path, :string, null: false
      add :role, :file_role, null: false
      add :mtime, :utc_datetime
      add :size, :integer

      add :component_id, references(:components, type: :binary_id, on_delete: :nilify_all)
      add :story_id, references(:stories, on_delete: :nilify_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:files, [:project_id, :path])
    create index(:files, [:component_id])
    create index(:files, [:story_id])
    create index(:files, [:role])
  end
end
