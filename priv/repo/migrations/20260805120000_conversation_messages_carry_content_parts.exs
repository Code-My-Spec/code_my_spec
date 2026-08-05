defmodule CodeMySpec.Repo.Migrations.ConversationMessagesCarryContentParts do
  @moduledoc """
  One message model for both the support widget and agent conversations.

  A message was a single `body` string plus a bespoke `attachments` list. That
  could not hold a tool call, so agent turns were flattened into text and
  `AgentConversationLive` grew two workarounds to cope: a clause for `role:
  :tool`, and one that hides blank-body turns so a tool-only turn does not read
  as an idle agent.

  The shape here is `ReqLLM.Message`'s, because that is what the provider hands
  us and translating it was the thing losing information: `content` is a list
  of typed parts, `tool_calls` rides on assistant turns, and `tool_call_id`
  pairs a result back to its call. A human message is one text part, and the
  attachments a support message already carried become file parts — the widget
  side had grown a parts list in all but name.

  `body` is dropped rather than kept as a derived preview. Two representations
  of the same text drift, and the one that drifts is always the one a human
  reads.

  `conversations.type` makes explicit what was inferred from a nil
  `session_external_id`. `list_conversations/1` had to remember to exclude agent
  threads so watching a sprite never raised the support inbox's unread badge;
  now it can filter.

  Backfill runs before anything is dropped, and `down` reverses it — text parts
  concatenate back into `body`, file parts back into `attachments`. Tool calls
  have nowhere to go in the old shape, so `down` discards them; that is a real
  loss and the reason not to roll back casually once agents are writing.
  """
  use Ecto.Migration

  def up do
    alter table(:conversations) do
      add :type, :string
    end

    execute """
    UPDATE conversations
       SET type = CASE WHEN session_external_id IS NULL THEN 'support' ELSE 'agent' END
    """

    execute "ALTER TABLE conversations ALTER COLUMN type SET NOT NULL"
    create index(:conversations, [:account_id, :type])

    alter table(:conversation_messages) do
      add :content, :jsonb
      add :tool_calls, :jsonb
      add :tool_call_id, :string
    end

    # A text part only when there was text — an attachment-only message had
    # body "" and must not gain an empty text part it never had.
    execute """
    UPDATE conversation_messages
       SET content =
         (CASE
            WHEN body IS NULL OR body = '' THEN '[]'::jsonb
            ELSE jsonb_build_array(jsonb_build_object('type', 'text', 'text', body))
          END)
         ||
         COALESCE(
           (SELECT jsonb_agg(jsonb_build_object('type', 'file', 'file', part))
              FROM jsonb_array_elements(attachments) AS part),
           '[]'::jsonb
         )
    """

    execute "ALTER TABLE conversation_messages ALTER COLUMN content SET NOT NULL"

    alter table(:conversation_messages) do
      remove :body
      remove :attachments
    end
  end

  def down do
    alter table(:conversation_messages) do
      add :body, :text
      add :attachments, :jsonb
    end

    execute """
    UPDATE conversation_messages
       SET body = COALESCE(
             (SELECT string_agg(part ->> 'text', E'\\n' ORDER BY ord)
                FROM jsonb_array_elements(content) WITH ORDINALITY AS t(part, ord)
               WHERE part ->> 'type' = 'text'),
             ''
           ),
           attachments = COALESCE(
             (SELECT jsonb_agg(part -> 'file')
                FROM jsonb_array_elements(content) AS part
               WHERE part ->> 'type' = 'file'),
             '[]'::jsonb
           )
    """

    execute "ALTER TABLE conversation_messages ALTER COLUMN body SET NOT NULL"
    execute "ALTER TABLE conversation_messages ALTER COLUMN attachments SET NOT NULL"

    alter table(:conversation_messages) do
      remove :content
      remove :tool_calls
      remove :tool_call_id
    end

    drop index(:conversations, [:account_id, :type])

    alter table(:conversations) do
      remove :type
    end
  end
end
