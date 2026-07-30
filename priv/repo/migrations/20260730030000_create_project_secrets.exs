defmodule CodeMySpec.Repo.Migrations.CreateProjectSecrets do
  use Ecto.Migration

  def change do
    create table(:project_secrets) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :value, :binary, null: false
      add :environment, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One row per project/key/environment. `environment` is NOT NULL
    # precisely so this index is honest — a nullable discriminator would
    # let duplicate keys coexist under Postgres NULL semantics.
    create unique_index(:project_secrets, [:project_id, :key, :environment])

    create index(:project_secrets, [:project_id])
  end
end
