defmodule CodeMySpec.Repo.Migrations.CreateConversationReads do
  use Ecto.Migration

  # Per-user read state for a conversation: when they last read it, and whether
  # they marked it unread since.
  def change do
    create table(:conversation_reads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :last_read_at, :utc_datetime_usec
      add :marked_unread, :boolean, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:conversation_reads, [:user_id, :conversation_id])
    create index(:conversation_reads, [:conversation_id])
  end
end
