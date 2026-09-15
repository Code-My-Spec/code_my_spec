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
  alias CodeMySpec.Files
  alias CodeMySpec.Paths
  alias CodeMySpec.Requirements.Registry, as: RequirementsRegistry
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @proposal_path Paths.proposal_path()

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{active_project_id: project_id} = scope, _entity)
      when not is_nil(project_id) do
    cond do
      not proposal_present?(scope) ->
        {false,
         %{
           reason:
             "`#{@proposal_path}` is missing — run an architecture session and write the proposal."
         }}

      (unlinked = unlinked_stories(scope)) != [] ->
        {false, %{reason: format_unlinked_stories(unlinked)}}

      (orphan_components = orphans(scope)) != [] ->
        {false, %{reason: format_orphans(orphan_components)}}

      true ->
        {true,
         %{status: "Architecture clean — every component is covered and every story is linked."}}
    end
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "No active project in scope — cannot verify architecture state."}}
  end

  # Asked of the synced files, not of a disk.
  #
  # This used to stat `@proposal_path` through the scope's environment, and
  # answered "Environment is not available" whenever there was none — which on
  # the light harness is always, because the server holds no working copy. An
  # agent wrote the proposal, watched it sync, and still got told it was
  # missing.
  #
  # Nothing was needed to fix that: files under `Paths.architecture_dir/0`
  # already sync with role `:architecture`, so a File row at that path is the
  # same evidence the stat was after, and it works with or without a disk.
  defp proposal_present?(scope), do: Files.get_by_path(scope, @proposal_path) != nil

  @doc """
  Returns the list of orphan **context** components in the project.

  Only context-shaped components (types where
  `RequirementsRegistry.has_children?/1` is true — `context`,
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

    # Only components this working copy actually has files for.
    #
    # Components are project-level and their ids are stable — stories and
    # requirements link to them, so they must be. Presence is the per-checkout
    # half, and `files` already carries it: `component_id` and `working_copy_id` on
    # the same row.
    #
    # Without this, a checkout that has not pulled re-projects components
    # another checkout deleted, and every agent is told to resolve the result.
    # `CodeMySpecLocalWeb.EpicsLive` was removed from the spec tree on
    # 2026-08-10 by `ad775a1`; three stale checkouts kept it alive, and the
    # working copies where the file was correctly gone were the ones asked to
    # fix it — with four resolutions that all act on a file they do not have.
    #
    # An unscoped read (the web UI, which names no harness) is unchanged: it
    # sees every checkout's files, which is what it should.
    present = Files.component_ids_present(scope)

    components
    |> Enum.filter(&context_shaped?/1)
    |> Enum.reject(fn c ->
      c.type == "infrastructure" or MapSet.member?(covered, c.id) or
        not MapSet.member?(present, c.id)
    end)
    |> Enum.sort_by(& &1.module_name)
  end

  defp context_shaped?(%{type: nil}), do: false
  defp context_shaped?(%{type: type}), do: RequirementsRegistry.has_children?(type)

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

  # Returns *released* project stories whose `component_id` is nil. These
  # stories have nothing to drive BDD spex / implementation against — the
  # architecture phase needs to assign them a surface component before
  # downstream work can proceed.
  #
  # Released only, which is the same rule `Preloader` states as "only released
  # stories project into the graph" and applies with
  # `where: s.ready_for_dev == true`. A parked story produces no requirements
  # by design, so holding the architecture open for one asks the architecture
  # phase to link a story nothing will act on.
  #
  # It is not a corner. Story 1038 was created during a Three Amigos re-run,
  # deliberately unlinked and deliberately unreleased pending its own session,
  # and `architecture_designed` became unsatisfiable the moment it existed.
  # That requirement is project-scoped and gates the story and component work
  # beneath it, so one parked story stopped every agent on the project: three
  # of them found nothing to do, and the only actionable requirement left was
  # the one that could not be satisfied. Creating a story in the way the
  # process asks for is what did it.
  defp unlinked_stories(%Scope{} = scope) do
    scope
    |> Stories.list_stories()
    |> Enum.filter(fn s -> Map.get(s, :ready_for_dev) == true end)
    |> Enum.filter(fn s -> Map.get(s, :component_id) == nil end)
    |> Enum.sort_by(& &1.id)
  end

  defp format_unlinked_stories(stories) do
    bullets =
      Enum.map_join(stories, "\n", fn s ->
        "- story `#{s.id}` — #{s.title}"
      end)

    """
    Architecture has #{length(stories)} unlinked story/stories — each needs a surface component before BDD spex or implementation can proceed:

    #{bullets}

    Resolve each via `set_story_component` (MCP tool) pointing at an existing component, or create the component first with `create_component` and then link.
    """
  end

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
    - Add a dependency edge from a story-linked context: edit that context's spec under `.code_my_spec/spec/` and add the orphan module as a bullet under `## Dependencies` (ComponentSync re-derives the graph on save)
    - Classify as infrastructure (edit the spec's `## Type` section to `infrastructure`; ComponentSync re-types on next sync)
    - Delete the context's spec, impl, and test files; ComponentSync will remove the component on the next sync
    """
  end
end
