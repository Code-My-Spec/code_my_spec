defmodule CodeMySpec.Conversations.Message do
  @moduledoc """
  A single message in a conversation. Plain-text `body` with an author
  identified by `(role, sender_id)`: role is `:user` (the end-user) or
  `:operator` (a CMS user in the account), with `:assistant` reserved for
  future LLM authors. Ordered by `inserted_at`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "conversation_messages" do
    field :body, :string
    field :role, Ecto.Enum, values: [:user, :operator, :assistant]
    field :sender_id, :string

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :role, :sender_id, :conversation_id])
    |> validate_required([:body, :role, :conversation_id])
  end
end
