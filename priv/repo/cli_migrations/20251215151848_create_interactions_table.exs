defmodule CodeMySpec.Repo.Migrations.CreateInteractionsTable do
  use Ecto.Migration

  def change do
    create table(:interactions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :step_name, :string
      add :command, :map, null: false
      add :result, :map
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:interactions, [:session_id])
    create index(:interactions, [:session_id, :inserted_at])
  end
end
