defmodule CodeMySpec.Requirements.Edge do
  @moduledoc """
  A dependency between two requirement nodes, as a row.

  `from` must be satisfied before `to` is actionable. That is the same direction
  `Topology` uses in memory, kept deliberately so nothing has to reverse it on
  the way in or out.

  Both ends are foreign keys to `requirements`, which is what lets this table
  carry no entity information: a node already records whether it belongs to a
  component, a story or a project.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Requirements.Node

  @type t :: %__MODULE__{
          id: integer() | nil,
          from_requirement_id: integer(),
          to_requirement_id: integer()
        }

  schema "requirement_edges" do
    belongs_to :from_requirement, Node
    belongs_to :to_requirement, Node

    timestamps(updated_at: false)
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from_requirement_id, :to_requirement_id])
    |> validate_required([:from_requirement_id, :to_requirement_id])
    |> validate_not_self_referential()
    |> foreign_key_constraint(:from_requirement_id)
    |> foreign_key_constraint(:to_requirement_id)
    |> unique_constraint([:from_requirement_id, :to_requirement_id])
  end

  # A node cannot gate itself. `Topology.transitive_reduction/1` assumes a DAG,
  # and a self-edge is a one-node cycle that would make the node permanently
  # unactionable rather than raising anything.
  defp validate_not_self_referential(changeset) do
    from = get_field(changeset, :from_requirement_id)
    to = get_field(changeset, :to_requirement_id)

    if from != nil and from == to do
      add_error(changeset, :to_requirement_id, "a requirement cannot depend on itself")
    else
      changeset
    end
  end
end
