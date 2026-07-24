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
    field :role, Ecto.Enum, values: [:user, :operator, :assistant, :tool]
    field :sender_id, :string
    # The speaking lane for agent-session transcripts: manager / product /
    # spec_writer / coding / qa. nil for human (user/operator) messages.
    field :agent_role, :string
    # Files shared in the message, copied into our S3 bucket, e.g.
    # %{"s3_key" => ..., "filename" => ..., "content_type" => ..., "size" => ...}.
    field :attachments, {:array, :map}, default: []

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(message, attrs) do
    message
    # Keep "" as-is (an attachment-only message has an empty body) rather than
    # letting Ecto nilify it into the NOT NULL `body` column.
    |> cast(attrs, [:body, :role, :sender_id, :conversation_id, :attachments], empty_values: [])
    |> validate_required([:role, :conversation_id])
    |> validate_body_or_attachments()
  end

  @doc """
  Changeset for a background-agent transcript line: carries the speaking lane in
  `agent_role`. Body may be empty (e.g. a bare tool call), so the
  body-or-attachments rule doesn't apply.
  """
  def agent_changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :role, :agent_role, :sender_id, :conversation_id], empty_values: [])
    |> validate_required([:role, :conversation_id])
  end

  # A message must carry either text or at least one attachment.
  defp validate_body_or_attachments(changeset) do
    body = get_field(changeset, :body)
    attachments = get_field(changeset, :attachments) || []

    if blank?(body) and attachments == [] do
      add_error(changeset, :body, "can't be blank without an attachment")
    else
      changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false
end
