defmodule CodeMySpec.Requirements do
  @moduledoc """
  Manages requirement checking and persistence.

  Provides two modes of checking requirements:
  - From definitions: Runs checkers to compute satisfaction status
  - From persisted requirements: Filters based on already-computed satisfaction

  Supports requirements at three levels:
  - Component: spec → tests → code → tests passing
  - Story: component linked → BDD specs → BDD specs passing → QA
  - Project: technical strategy → architecture → all stories → project QA
  """

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.{Requirement, RequirementDefinition, RequirementsRepository}
  alias CodeMySpec.Stories.Story

  @doc """
  Check artifact requirements with Registry fallback.

  First checks persisted requirements filtered by artifact_type.
  If none exist (not yet synced), falls back to running Registry-defined
  checkers live.
  """
  def check_artifact_requirements(scope, component, artifact_type) do
    requirements = component.requirements || []

    case check_requirements(scope, component, requirements,
           artifact_types: [artifact_type]
         ) do
      [] ->
        fallback =
          RequirementsRegistry.get_requirements_for_type(component.type)
          |> Enum.filter(&(&1.artifact_type == artifact_type))
          |> then(&check_requirements(scope, component, &1, []))

        if fallback == [] do
          Logger.warning(
            "[Requirements] No requirements found for #{component.module_name} " <>
              "(artifact_type: #{artifact_type})"
          )
        end

        fallback

      results ->
        results
    end
  end

  defdelegate clear_all_project_requirements(scope), to: RequirementsRepository
  defdelegate clear_requirements(scope, component, opts \\ []), to: RequirementsRepository
  defdelegate create_requirement(scope, component, attrs, opts \\ []), to: RequirementsRepository

  defdelegate create_story_requirement(scope, story, attrs, opts \\ []),
    to: RequirementsRepository

  defdelegate create_project_requirement(scope, project, attrs, opts \\ []),
    to: RequirementsRepository

  defdelegate clear_story_requirements(scope, story, opts), to: RequirementsRepository
  defdelegate clear_project_requirements(scope, project, opts), to: RequirementsRepository

  @doc """
  Returns actionable requirement definitions for an entity, grouped by `satisfied_by` module.

  Works for any entity recognized by `RequirementsRegistry.get_requirements/1`:
  - `%Component{}` — component-level requirements
  - `%Story{}` — story-level requirements
  - `%Project{}` — project-level requirements

  A definition is actionable when:
  - Its corresponding requirement is not yet satisfied (or doesn't exist yet)
  - It has a non-nil `satisfied_by` (meta requirements like `dependencies_satisfied` are excluded)
  - All prerequisites are met (satisfied or vacuously met — i.e., not a requirement for this type)

  Returns a map of `%{task_module => [RequirementDefinition.t()]}`.
  """
  @spec next_actionable(any(), Component.t() | Story.t() | Project.t()) :: %{
          module() => [RequirementDefinition.t()]
        }
  def next_actionable(_scope, entity) do
    definitions = RequirementsRegistry.get_requirements(entity)
    definition_names = MapSet.new(definitions, & &1.name)
    requirements = entity.requirements || []
    satisfaction_map = Map.new(requirements, &{&1.name, &1.satisfied})

    definitions
    |> Enum.filter(fn defn ->
      not Map.get(satisfaction_map, defn.name, false) and
        defn.satisfied_by != nil and
        prerequisites_met?(defn.prerequisites, satisfaction_map, definition_names)
    end)
    |> Enum.group_by(& &1.satisfied_by)
  end

  defp prerequisites_met?(prerequisites, satisfaction_map, definition_names) do
    Enum.all?(prerequisites, fn prereq ->
      if MapSet.member?(definition_names, prereq) do
        # This type has this requirement — must be satisfied
        Map.get(satisfaction_map, prereq, false)
      else
        # Not a requirement for this entity type → vacuously met
        true
      end
    end)
  end

  @doc """
  Checks requirements by either running checkers or filtering persisted records.

  ## With RequirementDefinition list (run checkers)

  Takes a list of RequirementDefinition structs, runs each checker, and returns
  check results (maps with satisfaction status).

  Use this when you need to compute fresh requirement status (e.g., during sync).

      iex> definitions = Components.get_requirement_definitions(scope, component, [])
      iex> check_requirements(scope, component, definitions, [])
      [%{name: "spec_file", satisfied: true, ...}, ...]

  ## With Requirement list (filter persisted)

  Takes a list of Requirement structs (from the database) and filters based on
  their already-computed `satisfied` field.

  Use this when you want to check status without re-running checkers (e.g., in agent tasks).

      iex> check_requirements(scope, component, component.requirements, [])
      [%Requirement{name: "spec_file", satisfied: true, ...}, ...]

      iex> check_requirements(scope, component, component.requirements, artifact_types: [:tests])
      [%Requirement{artifact_type: :tests, ...}, ...]

  ## Options (for filtering)

    * `:include` - list of requirement names to include (if empty, includes all)
    * `:exclude` - list of requirement names to exclude
    * `:artifact_types` - list of artifact types to filter by (if empty, includes all)

  """
  @spec check_requirements(any(), term(), [RequirementDefinition.t()], keyword()) :: [
          map()
        ]
  @spec check_requirements(any(), term(), [Requirement.t()], keyword()) :: [
          Requirement.t()
        ]
  def check_requirements(scope, entity, requirements_or_definitions, opts)

  def check_requirements(scope, entity, [%RequirementDefinition{} | _] = definitions, opts) do
    # Only create prerequisite edges for requirements that actually exist for this entity type
    definition_names = MapSet.new(definitions, & &1.name)

    Enum.map(definitions, fn requirement_definition ->
      checker = requirement_definition.checker
      result = checker.check(scope, requirement_definition, entity, opts)

      # Compute same-level prerequisite edges (only for prerequisites defined for this entity)
      prereq_edges =
        requirement_definition.prerequisites
        |> Enum.filter(&MapSet.member?(definition_names, &1))
        |> prerequisite_edges(entity)

      # Merge with any cross-entity edges the checker returned
      checker_edges = Map.get(result, :depends_on, [])

      result
      |> Map.put(:scope, requirement_definition.scope)
      |> Map.put(:satisfied_by, requirement_definition.satisfied_by)
      |> Map.put(:depends_on, prereq_edges ++ checker_edges)
    end)
  end

  def check_requirements(_scope, _entity, [] = _empty, _opts), do: []

  def check_requirements(_scope, _entity, [%Requirement{} | _] = requirements, opts) do
    include_types = Keyword.get(opts, :include, [])
    exclude_types = Keyword.get(opts, :exclude, [])
    artifact_types = Keyword.get(opts, :artifact_types, [])

    requirements
    |> Enum.filter(fn %Requirement{name: name, artifact_type: artifact_type} ->
      exclude = exclude_types != [] and name in exclude_types

      include =
        (include_types != [] and name in include_types) or include_types == []

      artifact_match =
        artifact_types == [] or artifact_type in artifact_types

      include && !exclude && artifact_match
    end)
  end

  # --- Graph query functions ---

  @doc """
  Returns all requirements that this requirement depends on (its blockers).
  Resolves depends_on edges to actual Requirement records.
  """
  @spec blocking(any(), Requirement.t()) :: [Requirement.t()]
  def blocking(_scope, %Requirement{depends_on: depends_on}) when is_list(depends_on) do
    RequirementsRepository.resolve_edges(depends_on)
  end

  def blocking(_scope, _), do: []

  @doc """
  Returns all requirements that depend on this requirement (it blocks them).
  """
  @spec blocked_by(any(), Requirement.t()) :: [Requirement.t()]
  def blocked_by(_scope, %Requirement{} = req) do
    RequirementsRepository.find_dependents(req)
  end

  @doc """
  Returns the full requirements graph for a project as nodes + edges.
  """
  @spec project_graph(any()) :: %{nodes: [Requirement.t()], edges: [map()]}
  def project_graph(scope) do
    RequirementsRepository.project_graph(scope)
  end

  @doc """
  Returns the next actionable requirements across the entire project
  (all entity levels).
  """
  @spec next_actionable_project(any()) :: [Requirement.t()]
  def next_actionable_project(scope) do
    RequirementsRepository.next_actionable_project(scope)
  end

  # --- Private helpers ---

  defp prerequisite_edges([], _entity), do: []

  defp prerequisite_edges(prerequisites, %Component{id: id}) do
    Enum.map(prerequisites, fn prereq_name ->
      %{"entity_type" => "component", "entity_id" => id, "requirement_name" => prereq_name}
    end)
  end

  defp prerequisite_edges(prerequisites, %Story{id: id}) do
    Enum.map(prerequisites, fn prereq_name ->
      %{"entity_type" => "story", "entity_id" => id, "requirement_name" => prereq_name}
    end)
  end

  defp prerequisite_edges(prerequisites, %Project{id: id}) do
    Enum.map(prerequisites, fn prereq_name ->
      %{"entity_type" => "project", "entity_id" => id, "requirement_name" => prereq_name}
    end)
  end
end
