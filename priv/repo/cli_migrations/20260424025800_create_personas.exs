defmodule CodeMySpec.Repo.Migrations.CreatePersonas do
  use Ecto.Migration

  def change do
    create table(:personas, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # CLI doesn't have an accounts table — account_id mirrors the server's
      # binary_id FK as a plain column so personas still filter by scope.
      add :account_id, :binary_id, null: false

      add :slug, :string, null: false
      add :name, :string, null: false
      add :headline, :string

      timestamps(type: :utc_datetime)
    end

    create index(:personas, [:account_id])
    create unique_index(:personas, [:account_id, :slug])
  end
end
