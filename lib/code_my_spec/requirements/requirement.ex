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
          orchestrated_by: atom() | nil,
          parent_entity_id: Ecto.UUID.t() | nil,
          parent_entity_name: String.t() | nil,
          render_command_always?: boolean(),
          role: atom() | nil,
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
    orchestrated_by: nil,
    parent_entity_id: nil,
    parent_entity_name: nil,
    render_command_always?: false,
    role: nil,
    prerequisites: [],
    details: %{}
  ]

  @doc """
  String-key a details map, so a computed requirement and a stored one carry the
  same shape.

  `details` is written to a `jsonb` column, which has no atoms — so a requirement
  that went through the database came back `%{"reason" => …}` while one computed
  in memory was `%{reason: …}`. Two shapes for one field, differing by which
  side answered.

  The cost was already visible in `RequirementsFormatter`: every clause written
  twice, atom and string, with a docstring noting the round trip. That is the
  benign version. The malignant one is a reader matching a single shape and
  silently falling through for the other — and which shape it gets depends on
  cache state, so it works until it doesn't.

  Strings, because `jsonb` cannot hold anything else and the projection is the
  served path. Normalizing in the other direction would mean
  `String.to_existing_atom/1` on database content, and a reason the graph has
  not seen before would raise where it used to render.

  Shallow by design: only the top level is a schema. Nested values are payloads
  — a `problems` list, an `errors` map keyed by file path — and stringifying
  those keys would be rewriting data, not normalizing a shape.
  """
  @spec normalize_details(map() | nil) :: map()
  def normalize_details(nil), do: %{}

  def normalize_details(details) when is_map(details) do
    Map.new(details, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
