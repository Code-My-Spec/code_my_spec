defmodule CodeMySpec.Requirements.Requirement do
  @moduledoc """
  A requirement node in the computed graph.

  Not persisted — computed on the fly from Files, Problems, and definitions.
  Carries entity_type/entity_id for grouping but the graph treats all nodes
  uniformly: edges are same-entity prerequisite links, cross-entity gates
  affect actionability only.
  """

  @type t :: %__MODULE__{
          entity_type: String.t(),
          entity_id: Ecto.UUID.t() | integer(),
          entity_name: String.t(),
          name: String.t(),
          description: String.t(),
          satisfied: boolean(),
          satisfied_by: module() | nil,
          scope: atom(),
          execution_type: :main_agent | :sub_agent,
          validation_type: :automatic | :manual,
          prerequisites: [String.t()],
          details: map()
        }

  @enforce_keys [:entity_type, :entity_id, :name, :satisfied]
  defstruct [
    :entity_type,
    :entity_id,
    :entity_name,
    :name,
    :description,
    :satisfied,
    :satisfied_by,
    scope: :local,
    execution_type: :main_agent,
    validation_type: :automatic,
    prerequisites: [],
    details: %{}
  ]
end
