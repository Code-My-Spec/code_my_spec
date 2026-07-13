defmodule CodeMySpec.ExternalUsers.ExternalUser do
  @moduledoc """
  A registered end-user of a target application, pushed to CodeMySpec by the
  app itself. Scoped to an account and project; keyed by email — the same
  identity `Conversation` threads on — so a repeat upsert refreshes the record
  rather than forking a duplicate. `external_id` carries the target app's own
  user id; `metadata` is a free-form bag for app-specific attributes (plan,
  version, platform, …).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "external_users" do
    field :account_id, :binary_id
    field :project_id, :binary_id
    field :external_id, :string
    field :email, :string
    field :name, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(external_user, attrs) do
    external_user
    |> cast(attrs, [:account_id, :project_id, :external_id, :email, :name, :metadata])
    |> validate_required([:account_id, :project_id, :email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/)
    |> unique_constraint([:project_id, :email])
  end
end
