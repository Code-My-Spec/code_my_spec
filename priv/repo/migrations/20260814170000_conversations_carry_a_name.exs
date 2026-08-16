defmodule CodeMySpec.Repo.Migrations.ConversationsCarryAName do
  use Ecto.Migration

  # A name you can set, so five agents are five names rather than five UUIDs.
  #
  # `session_external_id` is the grain and stays the identity — it is what the
  # recorder keys on and what appears in logs. This is the handle: generated
  # when the conversation is created so a row is never nameless, and editable
  # afterwards, because the useful name is "backend refactor" and only a person
  # knows that.
  #
  # Nullable with no default. Defaults belong on the schema, and a NULL here
  # reads correctly as "created before names existed" — those fall back to the
  # session id rather than being backfilled with a name nobody chose.
  def change do
    alter table(:conversations) do
      add :name, :string
    end
  end
end
