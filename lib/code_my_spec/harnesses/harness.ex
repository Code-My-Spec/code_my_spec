defmodule CodeMySpec.Harnesses.Harness do
  @moduledoc """
  One working copy the server knows about.

  The grain that files and problems belong to. A project id is shared by every
  checkout of a project; this is not, which is the whole point — a manifest is
  a statement about one checkout, and reconciling two of them against one set
  of rows makes each sync delete what the other just wrote.

  `label` is the harness's own description of itself and is display only. Two
  checkouts may carry the same label — two containers at `/workspace/app` on
  hosts with generated names produce identical strings — and still be two
  harnesses. That collision is exactly why identity is issued here instead of
  derived from anything the client can see.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          label: String.t() | nil,
          last_seen_at: DateTime.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "harnesses" do
    field :label, :string
    field :last_seen_at, :utc_datetime_usec

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(harness, attrs) do
    harness
    |> cast(attrs, [:label, :last_seen_at, :project_id])
    |> validate_required([:project_id])
    |> foreign_key_constraint(:project_id)
  end
end
