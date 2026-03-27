defmodule CodeMySpec.Requirements.RequirementsRepository do
  @moduledoc """
  Database operations for requirements across components, stories, and projects.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Gets a single requirement by ID, preloading the owning entity (component, story, or project).
  """
  @spec get_requirement!(integer()) :: Requirement.t()
  def get_requirement!(id) do
    Repo.get!(Requirement, id)
    |> Repo.preload([:component, :story, :project])
  end

  @spec get_requirement(integer()) :: Requirement.t() | nil
  def get_requirement(id) do
    Requirement
    |> Repo.get(id)
    |> Repo.preload([:component, :story, :project])
  end

  @doc """
  Clears all requirements for the entire project.
  """
  @spec clear_all_project_requirements(Scope.t()) :: {integer(), nil}
  def clear_all_project_requirements(%Scope{active_project_id: project_id}) do
    component_ids =
      Component
      |> where([c], c.project_id == ^project_id)
      |> select([c], c.id)

    # Clear component requirements
    Requirement
    |> where([r], r.component_id in subquery(component_ids))
    |> Repo.delete_all()

    # Clear story requirements for stories in this project
    story_ids =
      Story
      |> where([s], s.project_id == ^project_id)
      |> select([s], s.id)

    Requirement
    |> where([r], r.story_id in subquery(story_ids))
    |> Repo.delete_all()

    # Clear project-level requirements
    Requirement
    |> where([r], r.project_id == ^project_id)
    |> Repo.delete_all()
  end

  @spec create_requirement(Scope.t(), Component.t(), Requirement.requirement_attrs(), keyword()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def create_requirement(%Scope{}, %Component{} = component, attrs, opts \\ []) do
    changeset =
      %Requirement{}
      |> Requirement.changeset(attrs)
      |> Ecto.Changeset.put_assoc(:component, component)

    persist_or_apply(changeset, opts, :requirements_component_id_name_index)
  end

  @spec create_story_requirement(
          Scope.t(),
          Story.t(),
          Requirement.requirement_attrs(),
          keyword()
        ) :: {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def create_story_requirement(%Scope{}, %Story{} = story, attrs, opts \\ []) do
    changeset =
      %Requirement{}
      |> Requirement.changeset(Map.put(attrs, :story_id, story.id))

    persist_or_apply(changeset, opts, :requirements_story_id_name_index)
  end

  @spec create_project_requirement(
          Scope.t(),
          Project.t(),
          Requirement.requirement_attrs(),
          keyword()
        ) :: {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def create_project_requirement(%Scope{}, %Project{} = project, attrs, opts \\ []) do
    changeset =
      %Requirement{}
      |> Requirement.changeset(Map.put(attrs, :project_id, project.id))

    persist_or_apply(changeset, opts, :requirements_project_id_name_index)
  end

  @spec update_requirement(Scope.t(), Requirement.t(), Requirement.requirement_attrs()) ::
          {:ok, Requirement.t()} | {:error, Ecto.Changeset.t()}
  def update_requirement(%Scope{}, %Requirement{} = requirement, attrs) do
    requirement
    |> Requirement.update_changeset(attrs)
    |> Repo.update()
  end

  @spec clear_requirements(Scope.t(), Component.t(), list()) :: Component.t()
  def clear_requirements(%Scope{}, %Component{} = component, opts) do
    if Keyword.get(opts, :persist, false) do
      Requirement
      |> where([r], r.component_id == ^component.id)
      |> Repo.delete_all()
    end

    component
    |> Map.put(:outgoing_dependencies, [])
    |> Map.put(:incoming_dependencies, [])
  end

  @spec clear_story_requirements(Scope.t(), Story.t(), keyword()) :: Story.t()
  def clear_story_requirements(%Scope{}, %Story{} = story, opts) do
    if Keyword.get(opts, :persist, false) do
      Requirement
      |> where([r], r.story_id == ^story.id)
      |> Repo.delete_all()
    end

    story
  end

  @spec clear_project_requirements(Scope.t(), Project.t(), keyword()) :: Project.t()
  def clear_project_requirements(%Scope{}, %Project{} = project, opts) do
    if Keyword.get(opts, :persist, false) do
      Requirement
      |> where([r], r.project_id == ^project.id)
      |> Repo.delete_all()
    end

    project
  end

  @upsert_fields [
    :artifact_type,
    :description,
    :checker_module,
    :satisfied_by,
    :scope,
    :validation_type,
    :execution_type,
    :satisfied,
    :score,
    :checked_at,
    :details,
    :depends_on
  ]

  # Partial unique indexes require the WHERE clause for SQLite to match them.
  @conflict_fragments %{
    requirements_component_id_name_index:
      ~s|("component_id","name") WHERE "component_id" IS NOT NULL|,
    requirements_story_id_name_index:
      ~s|("story_id","name") WHERE "story_id" IS NOT NULL|,
    requirements_project_id_name_index:
      ~s|("project_id","name") WHERE "project_id" IS NOT NULL|
  }

  # --- Graph query functions ---

  @doc """
  Resolves depends_on edge maps to actual Requirement records.
  """
  @spec resolve_edges([map()]) :: [Requirement.t()]
  def resolve_edges([]), do: []

  def resolve_edges(edges) when is_list(edges) do
    # Group edges by entity type for efficient querying
    edges
    |> Enum.group_by(& &1["entity_type"])
    |> Enum.flat_map(fn {entity_type, type_edges} ->
      resolve_edges_for_type(entity_type, type_edges)
    end)
  end

  defp resolve_edges_for_type("component", edges) do
    pairs = Enum.map(edges, fn e -> {e["entity_id"], e["requirement_name"]} end)

    Requirement
    |> where([r], not is_nil(r.component_id))
    |> Repo.all()
    |> Enum.filter(fn r -> {r.component_id, r.name} in pairs end)
  end

  defp resolve_edges_for_type("story", edges) do
    pairs = Enum.map(edges, fn e -> {e["entity_id"], e["requirement_name"]} end)

    Requirement
    |> where([r], not is_nil(r.story_id))
    |> Repo.all()
    |> Enum.filter(fn r -> {r.story_id, r.name} in pairs end)
  end

  defp resolve_edges_for_type("project", edges) do
    pairs = Enum.map(edges, fn e -> {e["entity_id"], e["requirement_name"]} end)

    Requirement
    |> where([r], not is_nil(r.project_id))
    |> Repo.all()
    |> Enum.filter(fn r -> {r.project_id, r.name} in pairs end)
  end

  defp resolve_edges_for_type(_, _), do: []

  @doc """
  Finds all requirements that depend on the given requirement.
  Searches depends_on JSON arrays using SQLite LIKE on the serialized text.
  """
  @spec find_dependents(Requirement.t()) :: [Requirement.t()]
  def find_dependents(%Requirement{} = req) do
    {entity_type, entity_id} = entity_key(req)
    name = req.name

    # SQLite: depends_on is stored as JSON text, search for matching edge substring
    pattern = "%\"requirement_name\":\"#{name}\"%"

    Requirement
    |> where([r], fragment("? LIKE ?", r.depends_on, ^pattern))
    |> Repo.all()
    |> Enum.filter(fn r ->
      Enum.any?(r.depends_on || [], fn edge ->
        edge["entity_type"] == entity_type and
          edge["entity_id"] == entity_id and
          edge["requirement_name"] == name
      end)
    end)
  end

  @doc """
  Returns the full requirements graph for a project.
  """
  @spec project_graph(Scope.t()) :: %{nodes: [Requirement.t()], edges: [map()]}
  def project_graph(%Scope{active_project_id: project_id}) do
    component_ids =
      Component
      |> where([c], c.project_id == ^project_id)
      |> select([c], c.id)

    story_ids =
      Story
      |> where([s], s.project_id == ^project_id)
      |> select([s], s.id)

    nodes =
      Requirement
      |> where([r], r.component_id in subquery(component_ids))
      |> or_where([r], r.story_id in subquery(story_ids))
      |> or_where([r], r.project_id == ^project_id)
      |> Repo.all()

    edges =
      nodes
      |> Enum.flat_map(fn node ->
        (node.depends_on || [])
        |> Enum.map(fn edge ->
          %{
            from: edge,
            to: %{
              "entity_type" => entity_type(node),
              "entity_id" => entity_id(node),
              "requirement_name" => node.name
            }
          }
        end)
      end)

    %{nodes: nodes, edges: edges}
  end

  @doc """
  Returns next actionable requirements across all entity levels in a project,
  sorted by priority.

  A requirement is actionable when: not satisfied, has satisfied_by, all depends_on are satisfied.

  Sort order:
  - Project-level requirements first (by definition order)
  - Story-level requirements by story priority (lower = higher priority, nulls last)
  - Component-level requirements by owning story priority, then definition order
  """
  @spec next_actionable_project(Scope.t()) :: [Requirement.t()]
  def next_actionable_project(%Scope{} = scope) do
    %{nodes: all_requirements} = project_graph(scope)

    # Build lookup: {entity_type, entity_id, name} -> satisfied
    satisfaction_map =
      Map.new(all_requirements, fn r ->
        {{entity_type(r), entity_id(r), r.name}, r.satisfied}
      end)

    all_requirements
    |> Enum.filter(fn r ->
      not r.satisfied and
        r.satisfied_by != nil and
        all_deps_satisfied?(r.depends_on || [], satisfaction_map)
    end)
    |> sort_by_priority(scope)
  end

  defp all_deps_satisfied?([], _map), do: true

  defp all_deps_satisfied?(deps, satisfaction_map) do
    Enum.all?(deps, fn edge ->
      key = {edge["entity_type"], edge["entity_id"], edge["requirement_name"]}
      Map.get(satisfaction_map, key, true)
    end)
  end

  defp entity_key(%Requirement{component_id: id}) when not is_nil(id), do: {"component", id}
  defp entity_key(%Requirement{story_id: id}) when not is_nil(id), do: {"story", id}
  defp entity_key(%Requirement{project_id: id}) when not is_nil(id), do: {"project", id}

  defp entity_type(%Requirement{component_id: id}) when not is_nil(id), do: "component"
  defp entity_type(%Requirement{story_id: id}) when not is_nil(id), do: "story"
  defp entity_type(%Requirement{project_id: id}) when not is_nil(id), do: "project"

  defp entity_id(%Requirement{component_id: id}) when not is_nil(id), do: id
  defp entity_id(%Requirement{story_id: id}) when not is_nil(id), do: id
  defp entity_id(%Requirement{project_id: id}) when not is_nil(id), do: id

  # --- Private: priority sorting ---

  defp sort_by_priority(actionable_reqs, %Scope{active_project_id: project_id}) do
    # Load story priorities: surface_component_id -> story priority
    story_priorities =
      Story
      |> where([s], s.project_id == ^project_id)
      |> where([s], not is_nil(s.component_id))
      |> select([s], {s.component_id, s.priority})
      |> Repo.all()
      |> Map.new()

    # Build component_id -> story priority by walking parent chains to root
    component_story_map = build_component_story_map(project_id, story_priorities)

    Enum.sort_by(actionable_reqs, fn req ->
      cond do
        not is_nil(req.project_id) ->
          {0, 0, definition_order(req)}

        not is_nil(req.story_id) ->
          priority = story_priority_for(req.story_id, project_id)
          {1, priority, definition_order(req)}

        not is_nil(req.component_id) ->
          priority = Map.get(component_story_map, req.component_id, 999)
          {1, priority, definition_order(req)}
      end
    end)
  end

  defp story_priority_for(story_id, project_id) do
    Story
    |> where([s], s.id == ^story_id and s.project_id == ^project_id)
    |> select([s], s.priority)
    |> Repo.one()
    |> case do
      nil -> 999
      priority -> priority || 999
    end
  end

  defp build_component_story_map(project_id, story_priorities) do
    # Load all components with parent pointers
    components =
      Component
      |> where([c], c.project_id == ^project_id)
      |> select([c], {c.id, c.parent_component_id})
      |> Repo.all()

    parent_map = Map.new(components, fn {id, parent_id} -> {id, parent_id} end)

    # For each component, walk to root and look up story priority
    components
    |> Enum.map(fn {id, _} ->
      root_id = find_root_id(id, parent_map)
      priority = Map.get(story_priorities, root_id, 999)
      {id, priority}
    end)
    |> Map.new()
  end

  defp find_root_id(id, parent_map) do
    case Map.get(parent_map, id) do
      nil -> id
      parent_id -> find_root_id(parent_id, parent_map)
    end
  end

  defp definition_order(req) do
    definitions =
      cond do
        not is_nil(req.project_id) -> RequirementsRegistry.get_project_requirements()
        not is_nil(req.story_id) -> RequirementsRegistry.get_story_requirements()
        not is_nil(req.component_id) -> definition_order_for_component(req)
        true -> []
      end

    Enum.find_index(definitions, &(&1.name == req.name)) || 999
  end

  defp definition_order_for_component(req) do
    # Load component type to look up registry definitions
    case Repo.get(Component, req.component_id) do
      nil -> []
      component -> RequirementsRegistry.get_requirements_for_type(component.type)
    end
  end

  # --- Private: persistence ---

  defp persist_or_apply(changeset, opts, conflict_target) do
    if Keyword.get(opts, :persist, true) do
      fragment = Map.fetch!(@conflict_fragments, conflict_target)

      Repo.insert(changeset,
        on_conflict: {:replace, @upsert_fields},
        conflict_target: {:unsafe_fragment, fragment},
        returning: true
      )
    else
      Ecto.Changeset.apply_action(changeset, :insert)
    end
  end
end
