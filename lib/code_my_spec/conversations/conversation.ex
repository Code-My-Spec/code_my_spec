defmodule CodeMySpec.Conversations.Conversation do
  @moduledoc """
  One continuous thread between an end-user and the account. Scoped to an
  account and a project; keyed by the end-user's email so repeat contact
  appends to the same thread rather than forking a new one. `end_user_id`
  carries the target app's user id once known.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Conversations.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "conversations" do
    field :account_id, :binary_id
    field :project_id, :binary_id
    field :end_user_id, :string
    field :end_user_email, :string
    # Set for background-agent-session conversations (harness team's shared id);
    # nil for customer-support widget conversations.
    field :session_external_id, :string
    # A handle a person can set. `session_external_id` stays the identity — it
    # is what the recorder keys on and what shows up in logs — but a UUID tells
    # you nothing when five agents are running, so this is what the index shows.
    # Generated at creation, editable after; nil on rows created before names
    # existed, which fall back to the session id.
    field :name, :string
    field :read, :boolean, default: true
    field :status, Ecto.Enum, values: [:open, :closed], default: :open
    # Which kind of thread this is. Was inferred from a nil session_external_id,
    # which meant list_conversations/1 had to remember to exclude agent threads
    # so watching a sprite never raised the support inbox's unread badge.
    field :type, Ecto.Enum, values: [:support, :agent], default: :support

    has_many :messages, Message, preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:account_id, :project_id, :end_user_id, :end_user_email, :read, :status])
    |> put_change(:type, :support)
    |> validate_required([:account_id, :project_id, :end_user_email])
    |> unique_constraint([:account_id, :project_id, :end_user_email])
  end

  @doc """
  Changeset for a background-agent-session conversation: keyed by
  `session_external_id` instead of an end-user email (agents have no end user).
  """
  def agent_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:account_id, :project_id, :session_external_id, :read, :status, :name])
    |> put_change(:type, :agent)
    |> validate_required([:account_id, :project_id, :session_external_id])
    |> unique_constraint([:account_id, :project_id, :session_external_id],
      name: :conversations_account_project_session_index
    )
  end

  @doc """
  Rename a conversation, and nothing else.

  Separate from `agent_changeset/2` so the rename form cannot reach the session
  id or the account: a form that casts what it does not show is how a hidden
  field becomes an edit.

  A blank name clears it rather than storing `""` — the display falls back to
  the session id, which is the same thing an unnamed row does, and one empty
  state beats two.
  """
  def rename_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:name])
    |> update_change(:name, fn
      name when is_binary(name) -> if String.trim(name) == "", do: nil, else: String.trim(name)
      name -> name
    end)
    |> validate_length(:name, max: 120)
  end
end
