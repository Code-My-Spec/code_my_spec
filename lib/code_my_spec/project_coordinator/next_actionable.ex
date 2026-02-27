defmodule CodeMySpec.ProjectCoordinator.NextActionable do
  @moduledoc """
  Finds the next actionable requirement for a project by recursively
  descending: project → stories → components → dependencies.

  Returns the leaf `%Requirement{}` that has a `satisfied_by` task module,
  or `:complete` when all requirements are satisfied (or nothing is dispatchable).
  """

  alias CodeMySpec.Components
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @doc """
  Find the next actionable requirement for a project.

  Recursively descends: project → stories → components → dependencies.
  Returns `{:ok, %Requirement{}}` with a `satisfied_by` task module, or `:complete`.
  """
  @spec call(Scope.t(), struct()) :: {:ok, Requirement.t()} | :complete
  def call(%Scope{} = scope, entity) do
    entity = ensure_requirements_loaded(entity)

    entity.requirements
    |> find_stuck(entity)
    |> resolve(scope)
  end

  # Nothing stuck → complete
  defp resolve(nil, _scope), do: :complete

  # Has satisfied_by → actionable, return it
  defp resolve(%Requirement{satisfied_by: sb} = req, _scope) when not is_nil(sb) do
    {:ok, req}
  end

  # Project requirement, no satisfied_by → descend into stories
  defp resolve(%Requirement{project_id: pid} = _req, scope) when not is_nil(pid) do
    stories = load_stories(scope)

    Enum.find_value(stories, :complete, fn story ->
      case call(scope, story) do
        {:ok, _req} = found -> found
        :complete -> nil
      end
    end)
  end

  # Story requirement, no satisfied_by → descend into components
  defp resolve(%Requirement{story_id: sid} = _req, scope) when not is_nil(sid) do
    story = Stories.get_story!(scope, sid)
    descend_into_components(scope, story)
  end

  # Component requirement, no satisfied_by → descend into dependencies
  defp resolve(%Requirement{component_id: cid} = _req, scope) when not is_nil(cid) do
    all_components = Components.list_components_with_dependencies(scope)
    component = Enum.find(all_components, &(&1.id == cid))
    descend_into_dependencies(scope, component, all_components)
  end

  # ----------------------------------------------------------------
  # Descent helpers
  # ----------------------------------------------------------------

  defp descend_into_components(scope, story) do
    all_components = Components.list_components_with_dependencies(scope)
    component = Enum.find(all_components, &(&1.id == story.component_id))

    if is_nil(component) do
      :complete
    else
      case ProjectCoordinator.find_next_in_chain(component, all_components) do
        {:ready, focused} ->
          focused.requirements
          |> find_stuck(focused)
          |> resolve(scope)

        {:blocked, _} -> :complete
        :complete -> :complete
      end
    end
  end

  defp descend_into_dependencies(scope, component, all_components) do
    case ProjectCoordinator.find_next_in_chain(component, all_components) do
      {:ready, focused} ->
        focused.requirements
        |> find_stuck(focused)
        |> resolve(scope)

      {:blocked, _} -> :complete
      :complete -> :complete
    end
  end

  # ----------------------------------------------------------------
  # Core: find the stuck requirement
  # ----------------------------------------------------------------

  defp find_stuck(requirements, entity) when is_list(requirements) do
    definitions = RequirementsRegistry.get_requirements(entity)
    definition_names = MapSet.new(definitions, & &1.name)
    satisfaction_map = Map.new(requirements, &{&1.name, &1.satisfied})

    # Walk definitions in order, find first unsatisfied with met prereqs
    case Enum.find(definitions, fn defn ->
           not Map.get(satisfaction_map, defn.name, false) and
             prerequisites_met?(defn.prerequisites, satisfaction_map, definition_names)
         end) do
      nil ->
        nil

      defn ->
        # Return the actual Requirement record (not the definition).
        # If no DB record exists yet, build a virtual one from the definition.
        Enum.find(requirements, &(&1.name == defn.name)) ||
          virtual_requirement(defn, entity)
    end
  end

  defp prerequisites_met?(prereqs, satisfaction_map, definition_names) do
    Enum.all?(prereqs, fn prereq ->
      not MapSet.member?(definition_names, prereq) or
        Map.get(satisfaction_map, prereq, false)
    end)
  end

  # Build a virtual requirement from a definition when no DB record exists yet.
  defp virtual_requirement(defn, entity) do
    base = %Requirement{
      name: defn.name,
      artifact_type: defn.artifact_type,
      description: defn.description,
      satisfied_by: defn.satisfied_by,
      satisfied: false
    }

    case entity do
      %{__struct__: CodeMySpec.Projects.Project, id: id} -> %{base | project_id: id}
      %{__struct__: CodeMySpec.Stories.Story, id: id} -> %{base | story_id: id}
      %{__struct__: CodeMySpec.Components.Component, id: id} -> %{base | component_id: id}
    end
  end

  # ----------------------------------------------------------------
  # Loading helpers
  # ----------------------------------------------------------------

  defp load_stories(scope) do
    Stories.list_project_stories_by_priority(scope)
    |> Repo.preload(:requirements)
  end

  defp ensure_requirements_loaded(%{requirements: %Ecto.Association.NotLoaded{}} = entity) do
    Repo.preload(entity, :requirements)
  end

  defp ensure_requirements_loaded(%{requirements: reqs} = entity) when is_list(reqs), do: entity
  defp ensure_requirements_loaded(entity), do: Repo.preload(entity, :requirements)
end
