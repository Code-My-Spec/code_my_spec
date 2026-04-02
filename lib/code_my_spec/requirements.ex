defmodule CodeMySpec.Requirements do
  @moduledoc """
  Public API for the requirements graph.

  Requirements are computed on the fly from Files + Problems — not persisted.
  Three entity levels: component, story, project. The graph treats all nodes
  uniformly; cross-entity gates affect actionability but aren't edges.
  """

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  @doc """
  Returns the full computed requirements graph for a project.

  Nodes are `%Requirement{}` structs. Edges are same-entity prerequisite
  relationships only; cross-entity gates affect actionability status
  but are not represented as edges.
  """
  @spec project_graph(Scope.t()) :: %{nodes: [Requirement.t()], edges: [map()]}
  def project_graph(%Scope{} = scope) do
    nodes = RequirementGraph.compute_all(scope)

    edges =
      Enum.flat_map(nodes, fn node ->
        Enum.map(node.prerequisites, fn prereq_name ->
          %{
            from: %{entity_type: node.entity_type, entity_id: node.entity_id, name: prereq_name},
            to: %{entity_type: node.entity_type, entity_id: node.entity_id, name: node.name}
          }
        end)
      end)

    %{nodes: nodes, edges: edges}
  end

  @doc """
  Returns the next actionable requirements across the entire project,
  with cross-entity gates applied.
  """
  @spec next_actionable_project(Scope.t()) :: [Requirement.t()]
  def next_actionable_project(%Scope{} = scope) do
    RequirementGraph.next_actionable(scope)
  end

  @doc """
  Compute all requirement nodes across the project.
  """
  @spec compute_all(Scope.t()) :: [Requirement.t()]
  def compute_all(%Scope{} = scope) do
    RequirementGraph.compute_all(scope)
  end

  # --- Legacy shims (TODO: move evaluation criteria onto agent tasks) ---

  @doc """
  Check component requirements filtered by artifact_type.
  Bridges old agent task evaluate functions to the computed model.
  """
  def check_artifact_requirements(scope, %Component{} = component, artifact_type) do
    definitions = ComponentRegistry.get_requirements_for_type(component.type)

    definitions
    |> Enum.filter(&(&1.artifact_type == artifact_type))
    |> Enum.map(fn definition ->
      result = RequirementCalculator.compute_one(scope, component, definition, nil, nil)
      Map.merge(result, Map.from_struct(definition))
    end)
  end

  @doc false
  def check_requirements(_scope, _entity, requirements, opts) when is_list(requirements) do
    include_types = Keyword.get(opts, :include, [])
    exclude_types = Keyword.get(opts, :exclude, [])
    artifact_types = Keyword.get(opts, :artifact_types, [])

    requirements
    |> Enum.filter(fn req ->
      name = req[:name] || Map.get(req, :name)
      artifact = req[:artifact_type] || Map.get(req, :artifact_type)

      exclude = exclude_types != [] and name in exclude_types
      include = include_types == [] or name in include_types
      artifact_match = artifact_types == [] or artifact in artifact_types

      include and not exclude and artifact_match
    end)
  end

  @doc false
  def clear_all_project_requirements(_scope), do: :ok
end
