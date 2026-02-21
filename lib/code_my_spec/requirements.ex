defmodule CodeMySpec.Requirements do
  @moduledoc """
  Manages requirement checking and persistence.

  Provides two modes of checking requirements:
  - From definitions: Runs checkers to compute satisfaction status
  - From persisted requirements: Filters based on already-computed satisfaction
  """

  require Logger

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Components.Registry
  alias CodeMySpec.Requirements.{Requirement, RequirementDefinition, RequirementsRepository}

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
          Registry.get_requirements_for_type(component.type)
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
  @spec check_requirements(any(), Component.t(), [RequirementDefinition.t()], keyword()) :: [
          map()
        ]
  @spec check_requirements(any(), Component.t(), [Requirement.t()], keyword()) :: [
          Requirement.t()
        ]
  def check_requirements(scope, component, requirements_or_definitions, opts)

  def check_requirements(scope, component, [%RequirementDefinition{} | _] = definitions, opts) do
    Enum.map(definitions, fn requirement_definition ->
      checker = requirement_definition.checker
      checker.check(scope, requirement_definition, component, opts)
    end)
  end

  def check_requirements(_scope, _component, [] = _empty, _opts), do: []

  def check_requirements(_scope, _component, [%Requirement{} | _] = requirements, opts) do
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
end
