defmodule CodeMySpec.Repo.Migrations.DropInteractionsTables do
  @moduledoc """
  Drop `interactions` and `interaction_events`. The model they belonged to was
  deleted six months ago; only the tables were left behind.

  They were the storage half of session orchestration as it stood in
  `ce121d3e`: a session ran steps, each step an `Interaction` carrying a
  `command` and a `result`, with `interaction_events` an append-only log of
  what the agent did between the two. `1742e187` took the whole model out —
  `Sessions.Interaction`, `InteractionEvent`, `InteractionRegistry`,
  `InteractionsRepository`, `InteractionContext`, `RuntimeInteraction`,
  `Executor`, `Orchestrator`, `SessionServer` and twenty more besides. Nobody
  wrote the drop, so the tables outlived every module that knew their shape.

  What is left of `Sessions` is a session row with embedded tasks. There is no
  schema for either table, no reader, no writer, and zero rows in every
  database this working copy touches.

  Dropping them now rather than later because `interactions` is about to become
  a name we want. Agent-to-user messaging needs a `user_interactions` concept,
  and an empty table sitting next to it — with a live foreign key to `sessions`,
  which is exactly what makes it read as current — is a decoy that costs
  somebody an afternoon before they think to check `git log`.

  The matching leftover one layer down — the `sessions.interactions` column —
  is dropped by `20260817000000`, separately because this migration had already
  been applied by the time it was found.

  `down` recreates both, faithful to the originals except that `session_id` is
  declared `:binary_id` outright: it was a bigint when
  `20251215151848_create_interactions_table` wrote it and `20260118122845`
  converted it afterwards. Nothing restores the rows, because there were none.
  """
  use Ecto.Migration

  def up do
    # Events first: interaction_events.interaction_id references interactions.
    drop table(:interaction_events)
    drop table(:interactions)
  end

  def down do
    create table(:interactions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :step_name, :string
      add :command, :map, null: false
      add :result, :map
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:interactions, [:session_id])
    create index(:interactions, [:session_id, :inserted_at])

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
