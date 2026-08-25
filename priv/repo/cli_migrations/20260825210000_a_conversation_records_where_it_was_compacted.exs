defmodule CodeMySpec.Repo.Migrations.AConversationRecordsWhereItWasCompacted do
  use Ecto.Migration

  @moduledoc """
  Where an agent resumes from, when the transcript is longer than a context.

  Its own table rather than a flag or a role on `conversation_messages`. A
  checkpoint is a fact *about* a conversation rather than a thing said in one,
  and keeping it out of the message stream means no renderer, no `role` clause
  and no preview has to learn to skip it.

  `messages` is what the agent's own compaction decided to keep — the first
  message, the handoff summary it wrote, and the recent window. Stored as it
  came back rather than re-derived, so resuming lands the agent in the state
  compaction actually left it in instead of a second summary nobody read.

  `through_message_id` is where it stops. Everything after that row is replayed
  verbatim on top, which is what makes a checkpoint a bound on history rather
  than a truncation of it.
  """

  def change do
    create table(:conversation_checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :messages, {:array, :map}, null: false

      # Nullified rather than cascaded: losing the row a checkpoint stopped at
      # must not take the summary with it. A checkpoint with no anchor replays
      # the whole tail, which is wasteful and correct — the other way round
      # loses everything it summarised.
      add :through_message_id,
          references(:conversation_messages, type: :binary_id, on_delete: :nilify_all)

      # Which turn compacted, as the agent counted them. For reading a
      # transcript back, not for ordering — `inserted_at` orders these.
      add :turn, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversation_checkpoints, [:conversation_id])
  end
end
