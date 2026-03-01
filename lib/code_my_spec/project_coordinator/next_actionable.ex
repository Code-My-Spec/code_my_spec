defmodule CodeMySpec.ProjectCoordinator.NextActionable do
  @moduledoc """
  Finds the next actionable requirement for a project by recursively
  descending: project → stories → components → dependencies.

  Uses the `scope` field on requirements to control descent:
  - `:local` — return this requirement immediately
  - `:children` — descend into child entities in parallel (context → child components)
  - `:dependencies` — descend into serial dependency chain (project → stories, story → component tree, component → deps)

  Both `:children` and `:dependencies` return an error when descent finds nothing actionable.

  Expects all requirements to already be synced to the database. Does not
  fabricate virtual requirements from definitions.
  """

  require Logger

  alias CodeMySpec.Components
  alias CodeMySpec.ProjectCoordinator
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @doc """
  Find the next actionable requirement for an entity.

  Recursively descends based on requirement scope:
  - `:local` requirements are returned immediately
  - `:children` requirements descend into child entities (parallel — agent decides order)
  - `:dependencies` requirements descend into serial dependency chains (one at a time)

  Returns `{:ok, %Requirement{}}`, `:complete`, or `{:error, reason}`.
  """
  @spec call(Scope.t(), struct()) :: {:ok, Requirement.t()} | :complete | {:error, String.t()}
  def call(%Scope{} = scope, entity) do
    entity = ensure_requirements_loaded(entity)
    entity_label = entity_label(entity)

    case entity.requirements |> find_stuck(entity) |> resolve(scope) do
      {:ok, req} = result ->
        Logger.info("[NextActionable] #{entity_label} → stuck on #{req.name} (scope: #{req.scope}, task: #{inspect(req.satisfied_by)})")
        result

      :complete ->
        Logger.info("[NextActionable] #{entity_label} → complete")
        :complete

      {:error, reason} = error ->
        Logger.info("[NextActionable] #{entity_label} → error: #{reason}")
        error
    end
  end

  # ----------------------------------------------------------------
  # Resolve: dispatch on requirement scope
  # ----------------------------------------------------------------

  # Nothing stuck → complete
  defp resolve(nil, _scope), do: :complete

  # :local — return immediately regardless of satisfied_by
  defp resolve(%Requirement{scope: :local} = req, _scope) do
    {:ok, req}
  end

  # :orchestrate — same as :local, return immediately; Dispatch handles orchestration
  defp resolve(%Requirement{scope: :orchestrate} = req, _scope) do
    {:ok, req}
  end

  # :children — validate children have work, return PARENT requirement
  # The execution layer (Dispatch) orchestrates children via ProjectCoordinator
  defp resolve(%Requirement{scope: :children} = req, scope) do
    case descend_children(req, scope) do
      {:ok, _} ->
        {:ok, req}

      {:error, _} = error ->
        error

      :complete ->
        {:error,
         "requirement #{req.name} unsatisfied but all children are satisfied"}
    end
  end

  # :dependencies — descend into serial dependency chain, error if nothing found
  defp resolve(%Requirement{scope: :dependencies} = req, scope) do
    case descend_dependencies(req, scope) do
      {:ok, _} = found ->
        found

      {:error, _} = error ->
        error

      :complete ->
        {:error,
         "requirement #{req.name} unsatisfied but all dependencies are satisfied"}
    end
  end

  # ----------------------------------------------------------------
  # Descent: children (parallel — context → child components)
  # ----------------------------------------------------------------

  # Component → iterate child components (via parent_component_id)
  defp descend_children(%Requirement{component_id: cid}, scope) when not is_nil(cid) do
    children = Components.list_child_components(scope, cid)

    Enum.find_value(children, :complete, fn child ->
      child = ensure_requirements_loaded(child)

      case call(scope, child) do
        {:ok, _} = found -> found
        {:error, _} = error -> error
        :complete -> nil
      end
    end)
  end

  # ----------------------------------------------------------------
  # Descent: dependencies (serial — one at a time)
  # ----------------------------------------------------------------

  # Project → iterate stories in priority order
  defp descend_dependencies(%Requirement{project_id: pid}, scope) when not is_nil(pid) do
    stories = load_stories(scope)

    Enum.find_value(stories, :complete, fn story ->
      case call(scope, story) do
        {:ok, _} = found -> found
        {:error, _} = error -> error
        :complete -> nil
      end
    end)
  end

  # Story → get linked component, walk its dependency tree
  defp descend_dependencies(%Requirement{story_id: sid}, scope) when not is_nil(sid) do
    story = Stories.get_story!(scope, sid)
    all_components = Components.list_components_with_dependencies(scope)
    component = Enum.find(all_components, &(&1.id == story.component_id))

    if is_nil(component) do
      :complete
    else
      walk_dependency_chain(component, all_components, scope)
    end
  end

  # Component → walk its own dependency tree
  defp descend_dependencies(%Requirement{component_id: cid}, scope) when not is_nil(cid) do
    all_components = Components.list_components_with_dependencies(scope)
    component = Enum.find(all_components, &(&1.id == cid))
    walk_dependency_chain(component, all_components, scope)
  end

  defp walk_dependency_chain(component, all_components, scope) do
    case ProjectCoordinator.find_next_in_chain(component, all_components) do
      {:ready, focused} ->
        focused
        |> ensure_requirements_loaded()
        |> then(fn c -> find_stuck(c.requirements, c) end)
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
        Enum.find(requirements, &(&1.name == defn.name))
    end
  end

  defp prerequisites_met?(prereqs, satisfaction_map, definition_names) do
    Enum.all?(prereqs, fn prereq ->
      not MapSet.member?(definition_names, prereq) or
        Map.get(satisfaction_map, prereq, false)
    end)
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

  defp entity_label(%{module_name: name}), do: "component:#{name}"
  defp entity_label(%{title: title, id: id}), do: "story:##{id} \"#{title}\""
  defp entity_label(%{name: name}), do: "project:#{name}"
  defp entity_label(other), do: inspect(other.__struct__)
end
