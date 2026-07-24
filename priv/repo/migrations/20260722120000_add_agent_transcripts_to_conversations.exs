defmodule CodeMySpec.Repo.Migrations.AddAgentTranscriptsToConversations do
  @moduledoc """
  Lets the operator inbox host background-agent transcripts alongside the
  customer-support widget chats. An agent-session conversation is keyed by the
  harness `session_external_id` (the shared id for the whole Pi team) and has no
  end user, so `end_user_email` becomes nullable. Each message carries the
  speaking lane in `agent_role` (manager / product / spec_writer / coding / qa).
  """
  use Ecto.Migration

  def up do
    alter table(:conversations) do
      add :session_external_id, :string
    end

    # Agent-session conversations have no end user.
    execute "ALTER TABLE conversations ALTER COLUMN end_user_email DROP NOT NULL"

    # One conversation per (account, project, harness session). Partial so widget
    # conversations (session_external_id IS NULL) are unaffected.
    create unique_index(:conversations, [:account_id, :project_id, :session_external_id],
             where: "session_external_id IS NOT NULL",
             name: :conversations_account_project_session_index
           )

    alter table(:conversation_messages) do
      add :agent_role, :string
    end
  end

  def down do
    alter table(:conversation_messages) do
      remove :agent_role
    end

    drop index(:conversations, [:account_id, :project_id, :session_external_id],
           name: :conversations_account_project_session_index
         )

    # Restoring NOT NULL requires no rows to violate it.
    execute "DELETE FROM conversations WHERE end_user_email IS NULL"
    execute "ALTER TABLE conversations ALTER COLUMN end_user_email SET NOT NULL"

    alter table(:conversations) do
      remove :session_external_id
    end
  end
end
