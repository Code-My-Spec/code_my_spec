defmodule CodeMySpec.Conversations.ConversationRead do
  @moduledoc """
  One user's read state for one conversation.

  `last_read_at` is when they last read it; a message after it is unseen.
  `marked_unread` is their override, cleared the next time they read it.
  """

  use Ecto.Schema

  alias CodeMySpec.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "conversation_reads" do
    field :last_read_at, :utc_datetime_usec
    field :marked_unread, :boolean, default: false

    field :user_id, :id
    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime_usec)
  end
end
