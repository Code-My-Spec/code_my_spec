defmodule CodeMySpec.Repo.Migrations.AgentMailboxSendNow do
  use Ecto.Migration

  # Story 1051: a message sent now enters a running turn at its next tool
  # boundary. Every existing entry was queued for the turn's end.
  def change do
    alter table(:agent_mailbox) do
      add :send_now, :boolean
    end
  end
end
