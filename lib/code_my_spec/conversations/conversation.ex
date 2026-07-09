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
    field :read, :boolean, default: true
    field :status, Ecto.Enum, values: [:open, :closed], default: :open

    has_many :messages, Message, preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:account_id, :project_id, :end_user_id, :end_user_email, :read, :status])
    |> validate_required([:account_id, :project_id, :end_user_email])
    |> unique_constraint([:account_id, :project_id, :end_user_email])
  end
end
