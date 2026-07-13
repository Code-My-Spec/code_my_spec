defmodule CodeMySpec.Repo.Migrations.CreateExternalUsers do
  use Ecto.Migration

  def change do
    create table(:external_users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, :binary_id, null: false
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all), null: false
      add :external_id, :string
      add :email, :string, null: false
      add :name, :string
      add :metadata, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:external_users, [:project_id, :email])
    create index(:external_users, [:account_id])
  end
end
