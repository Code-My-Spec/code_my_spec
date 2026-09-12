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

    # Whose thread this is. An agent thread was keyed on the working copy and
    # held the whole team's transcript — deliberate, and it stopped serving once
    # a copy ran several lanes: their turns interleaved and a reply could not say
    # who spoke. The agent has an id, can be started and stopped, and is the
    # thing doing the talking, so it is the identity.
    field :agent_id, :binary_id

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
  Changeset for an agent's conversation, keyed by the agent (agents have no end
  user).

  `session_external_id` is still cast because a Claude Code lane reports itself
  by external id and is found that way; it is no longer what identifies the
  thread. An agent thread without an `agent_id` is the shape this replaced.
  """
  def agent_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :account_id,
      :project_id,
      :agent_id,
      :session_external_id,
      :read,
      :status,
      :name
    ])
    |> put_change(:type, :agent)
    |> validate_required([:account_id, :project_id])
    |> validate_keyed()
    |> unique_constraint(:agent_id, name: :conversations_agent_index)
    |> unique_constraint([:account_id, :project_id, :session_external_id],
      name: :conversations_account_project_session_index
    )
  end

  @doc """
  Renaming, which is the only thing about an agent thread a person changes.

  Separate from `agent_changeset/2` because that one asserts the keys — an
  account, a project, and something to find the row by again. A rename touches
  none of them, and routing it through a changeset that re-validates identity
  makes "you left the name blank" and "this row lost its agent" the same error.
  """
  def rename_changeset(conversation, name) do
    conversation
    |> cast(%{name: name}, [:name])
    |> update_change(:name, &trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
  end

  # `cast/3` has already turned a name that is only whitespace into `nil` — its
  # default empty values treat a blank-trimmed string as absent — so the change
  # this trims is not guaranteed to be a string. It stores the trimmed name; it
  # does not decide whether one was given, which `validate_required/2` does next.
  defp trim(name) when is_binary(name), do: String.trim(name)
  defp trim(name), do: name

  # An agent thread is found by its agent, or — for the threads that have no
  # agent, like a Claude Code lane before adoption or a story interview — by its
  # external id. With neither it is a row nothing can find again, so that fails
  # here rather than becoming a duplicate on the next lookup.
  defp validate_keyed(changeset) do
    case {get_field(changeset, :agent_id), get_field(changeset, :session_external_id)} do
      {nil, nil} ->
        add_error(
          changeset,
          :agent_id,
          "an agent conversation needs an agent, or a session id for the threads that have no agent"
        )

      _ ->
        changeset
    end
  end
end
