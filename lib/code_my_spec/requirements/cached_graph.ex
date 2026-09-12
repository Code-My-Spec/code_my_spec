defmodule CodeMySpec.Requirements.CachedGraph do
  @moduledoc """
  One project's last computed requirement graph. See
  `CodeMySpec.Requirements.GraphCache` for why it exists.
  """

  use Ecto.Schema

  alias CodeMySpec.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "requirement_graphs" do
    field :fingerprint, :string

    # What the *edges* were computed from, which is not what the nodes were
    # computed from. A partial recompute keeps the stored edges, and this is
    # what makes that safe to do: it moves when a dependency, a parent or the
    # config moves, and those are the only things that change an edge.
    field :topology_fingerprint, :string

    field :node_count, :integer
    field :edge_count, :integer
    field :computed_by, :string
    field :computed_at, :utc_datetime_usec

    belongs_to :project, Project, type: :binary_id

    # Whose view this graph is. A cached graph is not a property of a project:
    # `Preloader.load/1` scopes its file query to one checkout, so the
    # fingerprint covers what *that* checkout could see. Nil is the blended UI
    # vantage, which is a real one and gets its own row.
    field :working_copy_id, :binary_id

    timestamps(type: :utc_datetime)
  end
end
