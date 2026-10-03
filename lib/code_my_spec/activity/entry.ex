defmodule CodeMySpec.Activity.Entry do
  @moduledoc """
  One append-only activity row: what happened, on which resource and
  environment, and who did it. No changeset function accepts an existing
  struct for update — `Activity.record/4` always builds a fresh one, and
  there is no delete.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          environment: String.t() | nil,
          resource: String.t() | nil,
          kind: String.t() | nil,
          actor: String.t() | nil,
          summary: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "activity_entries" do
    field :project_id, :binary_id
    field :environment, :string
    field :resource, :string
    field :kind, :string
    field :actor, :string
    field :summary, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required [:project_id, :resource, :kind, :actor, :summary]

  @doc "The only changeset this schema has — there is no update."
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ [:environment])
    |> validate_required(@required)
  end
end
