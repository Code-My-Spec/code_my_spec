defmodule CodeMySpec.Requirements.ArchitectureChecker do
  @moduledoc """
  Delegate checker for the `architecture_designed` requirement on
  `project_graph`.

  Two obligations:

    * `proposal.md` exists at `Paths.proposal_path/0` (the artifact the
      architect produces).
    * Every non-infrastructure component in the project DB is either
      directly linked to a story, has a transitively story-linked
      descendant (parent-of-child case), or is a transitive dependency
      of a covered component. This is the live-DB analogue of
      `Architecture.Proposal.check_orphan_components/2` (Story 70 Rule
      10), which only fires at proposal-execute time. Without this
      checker, components synced from disk after the proposal executes
      drift in undetected.

  Returns `{boolean(), map()}` per the checker contract.
  Failure reasons name each orphan by `module_name` and `type`, with
  the canonical resolution menu (link a story, add a dep edge,
  classify as infrastructure, or delete).
  """

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Registry, as: ComponentRegistry
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Users.Scope

  @proposal_path Paths.proposal_path()

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{environment: env} = scope, _entity) when not is_nil(env) do
    if proposal_present?(env) do
      case orphans(scope) do
        [] ->
          {true, %{status: "Architecture clean — every component is covered."}}

        orphans ->
          {false, %{reason: format_orphans(orphans)}}
      end
    else
      {false,
       %{
         reason:
           "`#{@proposal_path}` is missing — run an architecture session and write the proposal."
       }}
    end
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "Environment is not available — cannot verify architecture state."}}
  end

  defp proposal_present?(env), do: Environments.file_exists?(env, @proposal_path) == true

  @doc """
  Returns the list of orphan **context** components in the project.

  Only context-shaped components (types where
  `ComponentRegistry.has_children?/1` is true — `context`,
  `coordination_context`, `live_context`) are subject to the orphan
  rule. Non-context components (liveview, controller, schema,
  module, etc.) are owned by their parent context and are not
  flagged on their own — that's the architectural unit we care
  about.

  An orphan context is one that is not directly story-linked, has
  no transitively story-linked descendant (via parent_component_id),
  and is not the target of a dependency from a covered component.

  Used by `complete?/2` to drive the gate, and by
  `AgentTasks.ArchitectureDesign.command/2` to surface the orphan
  diagnostic list in the architecture prompt.
  """
  @spec orphans(Scope.t()) :: [Components.Component.t()]
  def orphans(%Scope{} = scope) do
    components = Components.list_components_with_dependencies(scope)
    covered = covered_set(components)

    components
    |> Enum.filter(&context_shaped?/1)
    |> Enum.reject(fn c ->
      c.type == "infrastructure" or MapSet.member?(covered, c.id)
    end)
    |> Enum.sort_by(& &1.module_name)
  end

  defp context_shaped?(%{type: nil}), do: false
  defp context_shaped?(%{type: type}), do: ComponentRegistry.has_children?(type)

  # A component is "covered" when:
  #   1. It is directly story-linked, OR
  #   2. Any descendant (via parent_component_id) is covered, OR
  #   3. It is the target of a dependency from a covered component
  #      (transitive — chain through outgoing_dependencies).
  defp covered_set(components) do
    by_id = Map.new(components, &{&1.id, &1})
    seed = seed_covered(components)
    expand_through_deps(seed, by_id)
  end

  defp seed_covered(components) do
    direct =
      components
      |> Enum.filter(&story_linked?/1)
      |> MapSet.new(& &1.id)

    children_by_parent =
      components
      |> Enum.filter(& &1.parent_component_id)
      |> Enum.group_by(& &1.parent_component_id)

    Enum.reduce(components, direct, fn comp, acc ->
      if any_descendant_in?(comp, children_by_parent, direct) do
        MapSet.put(acc, comp.id)
      else
        acc
      end
    end)
  end

  defp any_descendant_in?(comp, children_by_parent, target_set, visited \\ MapSet.new()) do
    if MapSet.member?(visited, comp.id) do
      false
    else
      visited = MapSet.put(visited, comp.id)
      children = Map.get(children_by_parent, comp.id, [])

      Enum.any?(children, fn child ->
        MapSet.member?(target_set, child.id) or
          any_descendant_in?(child, children_by_parent, target_set, visited)
      end)
    end
  end

  defp story_linked?(%{stories: stories}) when is_list(stories), do: stories != []
  defp story_linked?(_), do: false

  defp expand_through_deps(seed, by_id) do
    do_expand(seed, MapSet.to_list(seed), by_id)
  end

  defp do_expand(visited, [], _by_id), do: visited

  defp do_expand(visited, [id | rest], by_id) do
    case Map.get(by_id, id) do
      nil ->
        do_expand(visited, rest, by_id)

      comp ->
        new_neighbors =
          comp
          |> dep_target_ids()
          |> Enum.reject(&MapSet.member?(visited, &1))

        visited = Enum.reduce(new_neighbors, visited, &MapSet.put(&2, &1))
        do_expand(visited, rest ++ new_neighbors, by_id)
    end
  end

  defp dep_target_ids(%{dependencies: deps}) when is_list(deps), do: Enum.map(deps, & &1.id)
  defp dep_target_ids(_), do: []

  defp format_orphans(orphans) do
    bullets =
      Enum.map_join(orphans, "\n", fn c ->
        "- `#{c.module_name}` (type: `#{c.type || "module"}`)"
      end)

    """
    Architecture has #{length(orphans)} orphan context(s) — contexts not linked to a story, not transitively depended on by a story-linked context, and not classified as infrastructure:

    #{bullets}

    Resolve each orphan via one of:
    - Link a story (`set_story_component`)
    - Add a dependency edge from a story-linked context (`create_dependency`)
    - Classify as infrastructure (add the file path to `infrastructure_paths` in `.code_my_spec/config.yml`)
    - Delete the context's spec, impl, and test files; ComponentSync will remove the component on the next sync
    """
  end
end
