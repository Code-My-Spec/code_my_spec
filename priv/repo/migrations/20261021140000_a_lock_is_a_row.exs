defmodule CodeMySpec.Repo.Migrations.ALockIsARow do
  use Ecto.Migration

  # `Repo.lock!/1`: a row per key, locked FOR UPDATE, in place of Postgres
  # advisory locks, which SQLite has no equivalent of.
  def change do
    create table(:locks, primary_key: false) do
      add :key, :string, primary_key: true
    end
  end
end
