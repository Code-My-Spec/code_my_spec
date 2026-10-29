defmodule CodeMySpec.Requirements.ProjectTopology do
  @moduledoc """
  A project's edge set, as one row: the edges as generated, their transitive
  reduction for views, and the topology hash they were drawn from.

  Edges are erlang terms (`{entity_type, entity_id, name}` pairs), written and
  read only through `GraphStore`.
  """

  use Ecto.Schema

  @primary_key {:project_id, :binary_id, autogenerate: false}

  schema "requirement_topologies" do
    field :topology, :string
    field :edges, :binary
    field :display_edges, :binary

    timestamps(type: :utc_datetime_usec)
  end
end
