defmodule CodeMySpec.Repo.SqliteMigrations.AProjectDrawsItsEdgesOnce do
  use Ecto.Migration

  def change do
    create table(:requirement_topologies, primary_key: false) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :topology, :string, null: false
      add :edges, :binary, null: false
      add :display_edges, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
