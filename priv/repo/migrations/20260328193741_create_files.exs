defmodule CodeMySpec.Repo.Migrations.CreateFiles do
  use Ecto.Migration

  # `story_id` is NOT created here even though the schema declares
  # `belongs_to :story`. Production was migrated against an earlier
  # working copy of this file that did not include the column, so its
  # `files` table came out without it. The column is added later by
  # `20260518020500_add_story_id_to_files`, which is idempotent so
  # fresh dev/CI environments end up in the same state.

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
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:files, [:project_id, :path])
    create index(:files, [:component_id])
    create index(:files, [:role])
  end
end
