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
    field :payload, :binary
    field :node_count, :integer
    field :edge_count, :integer
    field :computed_by, :string
    field :computed_at, :utc_datetime_usec

    belongs_to :project, Project, type: :binary_id

    timestamps(type: :utc_datetime)
  end
end
