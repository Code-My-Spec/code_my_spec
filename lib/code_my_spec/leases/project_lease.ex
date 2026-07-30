defmodule CodeMySpec.Leases.ProjectLease do
  @moduledoc """
  A label for whoever currently holds a project's files.

  Not the lease. The lease is an advisory lock on `Leases.Session`'s
  connection — see `CodeMySpec.Leases` for why. This row exists so a refusal
  can name the checkout to go and stop, which two integers cannot.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          holder_label: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "project_leases" do
    field :project_id, :binary_id
    field :holder_label, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [:project_id, :holder_label])
    |> validate_required([:project_id])
    |> unique_constraint(:project_id)
  end
end
