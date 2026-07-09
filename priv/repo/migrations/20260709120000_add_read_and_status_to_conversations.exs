defmodule CodeMySpec.Repo.Migrations.AddReadAndStatusToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # Account-level read flag: cleared when an end-user sends, set when a
      # teammate opens or replies. Drives the inbox's unread indicator.
      add :read, :boolean, null: false, default: true
      # Triage lifecycle: "open" (needs attention) or "closed" (handled).
      add :status, :string, null: false, default: "open"
    end

    create index(:conversations, [:account_id, :read])
  end
end
