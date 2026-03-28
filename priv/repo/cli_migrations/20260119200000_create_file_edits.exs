defmodule CodeMySpec.Repo.Migrations.CreateFileEdits do
  use Ecto.Migration

  def change do
    create table(:file_edits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_session_id, :string, null: false
      add :file_path, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:file_edits, [:external_session_id])
    create unique_index(:file_edits, [:external_session_id, :file_path])
  end
end
