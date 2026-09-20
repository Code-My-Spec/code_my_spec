defmodule CodeMySpec.Requirements.StoryExecution do
  @moduledoc """
  The work offered to one working copy's explicitly selected story.

  Membership narrows the answer, never the graph used to check prerequisites.
  The project graph remains available for status and dependency diagnostics.
  """
  alias CodeMySpec.Requirements.{GraphWatcher, Preloader, RequirementGraph}
  alias CodeMySpec.{Stories, WorkingCopies}

  @completion_names ~w(component_linked three_amigos_complete bdd_specs_exist bdd_specs_passing code_on_running_copy qa_complete story_issues_resolved)

  def read(scope, role \\ nil, requested_story_id \\ nil) do
    with {:ok, copy} <- WorkingCopies.fetch(scope.active_working_copy_id),
         true <- copy.project_id == scope.active_project_id,
         :ok <- GraphWatcher.settle(scope),
         {:ok, ctx} <- Preloader.load(scope),
         {{nodes, edges}, _actionable, _at} <-
           RequirementGraph.cached_graph_with_actionable(scope) do
      case selected(scope, copy, requested_story_id) do
        {:ok, story} -> from_graph(story, nodes, edges, ctx, role)
        :none -> from_copy(nodes, edges, ctx, role)
      end
    else
      _ -> result(:unavailable, nil, "This session has no working copy on this project.")
    end
  end

  # The story this copy has selected, if it has selected one that is still
  # eligible. A requested id that is not the selected one answers `:none`
  # rather than the project: asking for another story's work is not a reason to
  # widen the answer.
  defp selected(scope, copy, requested_story_id) do
    with id when not is_nil(id) <- copy.active_story_id,
         true <- is_nil(requested_story_id) or to_string(requested_story_id) == to_string(id),
         %{ready_for_dev: true} = story <- Stories.get_story(scope, id),
         true <- story.working_copy_id == copy.id do
      {:ok, story}
    else
      _ -> :none
    end
  end

  # No story selected, which is not the same as nothing to do.
  #
  # The copy is answered for the project, which is what it was answered for
  # before slicing existed. Two things depend on that and neither is inside any
  # story: the fourteen project-level requirements — `issues_triaged`,
  # `architecture_designed`, `work_dispatched` and QA's whole journey chain —
  # and a story that has been released but assigned to nobody yet, which is how
  # work reaches an idle agent in the first place.
  #
  # Story 1005's rule is that work appearing on the graph reaches the agent who
  # can do it, and stories 1015, 1046, 1047 and 1048 are 33 spex defending it.
  # Narrowing this to "project requirements plus stories already assigned here"
  # left a freshly released story waking nobody.
  defp from_copy(nodes, edges, ctx, role) do
    case actionable_nodes(nodes, edges, ctx, role) do
      [] ->
        result(:complete, nil, empty_reason(nodes, edges, ctx))

      actionable ->
        wave = next_wave(actionable)

        %{
          result(:ready, nil, "")
          | actionable: actionable,
            wave: wave,
            remaining: length(actionable) - length(wave)
        }
    end
  end

  # Nothing for this role, and whether that is a finished project or somebody
  # else's queue is a distinction `RequirementsMapper` records at length: a
  # coding agent once reported "All requirements satisfied" against three
  # unsatisfied requirements that were product's, which reads as a finished
  # project to whoever is watching.
  #
  # Asked of the *actionable* set rather than the unsatisfied one. A requirement
  # that is unsatisfied and blocked is nobody's queue right now, and calling that
  # an unfinished project would make the terminal state unreachable — story
  # 1015's criterion 2393 is the one that says an agent with nothing to do is
  # allowed to stop.
  defp empty_reason(nodes, edges, ctx) do
    case actionable_nodes(nodes, edges, ctx, nil) do
      [] ->
        "# All requirements satisfied\n\nNo actionable requirements remain."

      elsewhere ->
        "Nothing for this role right now. #{length(elsewhere)} actionable requirement(s) in " <>
          "this project belong to other roles — this is not a finished project. Select a " <>
          "story with set_active_story when one is ready."
    end
  end

  defp actionable_nodes(nodes, edges, context, nil),
    do: RequirementGraph.actionable_from(nodes, edges, context)

  defp actionable_nodes(nodes, edges, context, role),
    do: RequirementGraph.actionable_for_role_from(nodes, edges, context, role)

  @doc false
  def from_graph(story, nodes, edges, ctx, role) do
    nodes = Enum.sort_by(nodes, &{&1.entity_name || "", &1.name, to_string(&1.entity_id)})
    ids = RequirementGraph.story_component_ids(story, ctx)
    local = Enum.filter(nodes, &member?(&1, story.id, ids))
    questions = Enum.filter(Map.get(ctx.questions_by_story, story.id, []), &(&1.status == :open))
    story_nodes = Enum.filter(local, &(&1.entity_type == "story"))
    present = MapSet.new(story_nodes, & &1.name)
    missing = Enum.reject(@completion_names, &MapSet.member?(present, &1))
    context = Map.merge(ctx, %{stories: [story], execution_component_ids: ids})

    cond do
      questions != [] ->
        result(
          :blocked,
          story,
          "Unanswered questions: " <> Enum.map_join(questions, "; ", & &1.text)
        )

      missing != [] ->
        result(
          :blocked,
          story,
          "Story requirements are not available: " <>
            Enum.join(missing, ", ") <> ". Sync this working copy."
        )

      true ->
        actionable =
          nodes
          |> actionable_nodes(edges, context, role)
          |> Enum.filter(&member?(&1, story.id, ids))

        open = Enum.reject(local, & &1.satisfied)
        blockers = blocking_nodes(nodes, edges, local)

        cond do
          open == [] and blockers == [] ->
            result(
              :complete,
              story,
              "This story is complete for the working copy. Select another story explicitly when ready."
            )

          actionable != [] ->
            wave = next_wave(actionable)

            %{
              result(:ready, story, "")
              | actionable: actionable,
                wave: wave,
                remaining: length(actionable) - length(wave)
            }

          true ->
            %{
              result(
                :blocked,
                story,
                "No work is actionable for this role on the active story. The story is not complete."
              )
              | blockers: Enum.uniq_by(blockers ++ open, &key/1)
            }
        end
    end
  end

  defp member?(%{entity_type: "story", entity_id: id, name: name}, story_id, _ids),
    do: to_string(id) == to_string(story_id) and name in @completion_names

  defp member?(%{entity_type: "component", entity_id: id}, _story_id, ids),
    do: MapSet.member?(ids, id)

  defp member?(_, _, _), do: false

  # Follow incoming edges through satisfied nodes too: local satisfaction does
  # not erase an unmet external prerequisite. Cycle-safe for malformed input.
  defp blocking_nodes(nodes, edges, local) do
    incoming = Enum.group_by(edges, & &1.to, & &1.from)
    ancestors = ancestors(Enum.map(local, &key/1), incoming, MapSet.new())
    Enum.filter(nodes, &(not &1.satisfied and MapSet.member?(ancestors, key(&1))))
  end

  defp ancestors([], _incoming, seen), do: seen

  defp ancestors([key | rest], incoming, seen) do
    if MapSet.member?(seen, key) do
      ancestors(rest, incoming, seen)
    else
      ancestors(Map.get(incoming, key, []) ++ rest, incoming, MapSet.put(seen, key))
    end
  end

  defp next_wave([%{orchestrated_by: nil} = first | _]), do: [first]

  defp next_wave([first | _] = nodes) do
    Enum.filter(
      nodes,
      &({&1.orchestrated_by, &1.parent_entity_id} ==
          {first.orchestrated_by, first.parent_entity_id})
    )
  end

  defp key(node), do: {node.entity_type, node.entity_id, node.name}

  defp result(status, story, reason),
    do: %{
      status: status,
      story: story,
      actionable: [],
      wave: [],
      remaining: 0,
      blockers: [],
      reason: reason
    }
end
