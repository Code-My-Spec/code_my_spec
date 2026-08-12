defmodule CodeMySpec.Repo.Migrations.ConversationMessagesRecordOrigin do
  use Ecto.Migration

  def change do
    alter table(:conversation_messages) do
      # Where the message was sent from, as the widget's host app reported it
      # at connect time. Nil for every message that predates this and for the
      # operator's own replies, which do not come through a widget.
      add :origin, :string
    end
  end
end
