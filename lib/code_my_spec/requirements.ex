defmodule CodeMySpec.Requirements do
  @moduledoc """
  Public API for the requirements graph.

  Requirements are computed on the fly from Files + Problems — not persisted.
  Three entity levels: component, story, project. The graph treats all nodes
  uniformly; cross-entity gates affect actionability but aren't edges.
  """

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Files
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  @doc """
  Returns the full computed requirements graph for a project.

  Nodes are `%Requirement{}` structs. Edges include both same-entity
  prerequisites and cross-entity dependencies (component tree → story,
  stories → project). The graph is complete — actionability is determined
  purely by edge traversal.
  """
  @spec project_graph(Scope.t()) :: %{nodes: [Requirement.t()], edges: [map()]}
  def project_graph(%Scope{} = scope) do
    {nodes, edges} = RequirementGraph.compute_graph(scope)
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
  Returns the full computed requirements graph plus the next actionable
  requirements, computed in a single pass.

  Use this when you need both views — saves a duplicate preload + graph
  compute compared to calling `project_graph/1` and
  `next_actionable_project/1` separately.
  """
  @spec project_graph_with_actionable(Scope.t()) ::
          %{nodes: [Requirement.t()], edges: [map()], actionable: [Requirement.t()]}
  def project_graph_with_actionable(%Scope{} = scope) do
    {nodes, edges, actionable} = RequirementGraph.compute_graph_with_actionable(scope)
    %{nodes: nodes, edges: edges, actionable: actionable}
  end

  @doc """
  Same as `project_graph_with_actionable/1` plus per-phase timings.
  """
  @spec project_graph_with_actionable_metrics(Scope.t()) ::
          {%{nodes: [Requirement.t()], edges: [map()], actionable: [Requirement.t()]},
           %{atom() => integer()}}
  def project_graph_with_actionable_metrics(%Scope{} = scope) do
    {{nodes, edges, actionable}, metrics} =
      RequirementGraph.compute_graph_with_actionable_metrics(scope)

    {%{nodes: nodes, edges: edges, actionable: actionable}, metrics}
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
  Compute all requirements for a component with satisfaction status.
  Returns a list of maps with requirement definition fields plus `:satisfied`.
  """
  def compute_component_requirements(scope, %Component{} = component) do
    definitions = ComponentRegistry.get_requirements_for_type(component.type)
    files = Files.list_component_files(scope, component.id)

    Enum.map(definitions, fn definition ->
      result = RequirementCalculator.compute_one(scope, component, definition, files)
      Map.merge(result, Map.from_struct(definition))
    end)
  end

  @doc """
  Check component requirements filtered by artifact_type.
  Bridges old agent task evaluate functions to the computed model.
  """
  def check_artifact_requirements(scope, %Component{} = component, artifact_type) do
    scope
    |> compute_component_requirements(component)
    |> Enum.filter(&(&1.artifact_type == artifact_type))
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
