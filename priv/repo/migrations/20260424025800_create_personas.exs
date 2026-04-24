defmodule CodeMySpec.Repo.Migrations.CreatePersonas do
  use Ecto.Migration

  def change do
    create table(:personas, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :slug, :string, null: false
      add :name, :string, null: false
      add :headline, :string

      timestamps(type: :utc_datetime)
    end

    create index(:personas, [:account_id])
    create unique_index(:personas, [:account_id, :slug])
  end
end
