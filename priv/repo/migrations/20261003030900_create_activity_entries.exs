defmodule CodeMySpec.Repo.Migrations.CreateActivityEntries do
  use Ecto.Migration

  # Append-only: every provision, check, deploy, credential save, secret
  # write and environment edit a project sees, attributed to whoever made
  # it. No `updated_at` — nothing here is ever revised, and `Activity`
  # exposes no update or delete.
  def change do
    create table(:activity_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :environment, :string
      add :resource, :string, null: false
      add :kind, :string, null: false
      add :actor, :string, null: false
      add :summary, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:activity_entries, [:project_id, :inserted_at])
    create index(:activity_entries, [:project_id, :resource, :inserted_at])
  end
end
