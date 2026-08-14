defmodule CodeMySpec.Repo.Migrations.ConversationMessagesRecordToolFailure do
  use Ecto.Migration

  # Whether a tool result came back an error.
  #
  # The recorder used to fold this into the text — `"← failed: …"` versus
  # `"← result: …"` — and the view read it back by matching the prefix. That
  # made a rendering decision depend on parsing prose the model never wrote,
  # and it is the same class of guess as `tool_name?/1` ("a tool name is one
  # token"), which this change removes.
  #
  # Anthropic sends `is_error` as a boolean on the `tool_result` block. Keeping
  # it as one means the view asks a field instead of a string.
  #
  # No default here — schema defaults belong on the schema, and a NULL reads
  # correctly as "not a tool result".
  def change do
    alter table(:conversation_messages) do
      add :tool_failed, :boolean
    end
  end
end
