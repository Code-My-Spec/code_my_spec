defmodule CodeMySpec.Repo.Migrations.ConvertSessionEventsToInteractionEvents do
  use Ecto.Migration

  def change do
    # Drop the old session_events table
    drop_if_exists table(:session_events)

    # Create new interaction_events table
    create table(:interaction_events) do
      add :interaction_id, references(:interactions, type: :uuid, on_delete: :delete_all),
        null: false

      add :event_type, :string, null: false
      add :data, :map
      add :metadata, :map
      add :sent_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:interaction_events, [:interaction_id])
    create index(:interaction_events, [:interaction_id, :sent_at])
  end
end
