defmodule CodeMySpec.Requirements.StoryExecution do
  @moduledoc """
  The work offered to one working copy's explicitly selected story.

  Membership narrows the answer, never the graph used to check prerequisites.
  The project graph remains available for status and dependency diagnostics.
  """
  alias CodeMySpec.Requirements.{GraphWatcher, Preloader, RequirementGraph}
  alias CodeMySpec.{Stories, WorkingCopies}

  @completion_names ~w(component_linked three_amigos_complete questions_answered bdd_specs_exist bdd_specs_passing story_promoted qa_complete story_issues_resolved story_issues_triaged)

  # `withheld?` drops nodes the caller cannot claim — its own blocked task, or
  # another agent's at this checkout — before the wave is cut (467310a7).
  def read(scope, role \\ nil, requested_number \\ nil, withheld? \\ fn _ -> false end) do
    with {:ok, copy} <- WorkingCopies.fetch(scope.active_working_copy_id),
         true <- copy.project_id == scope.active_project_id,
         :ok <- GraphWatcher.settle(scope),
         {:ok, ctx} <- Preloader.load(scope),
         ctx = Map.put(ctx, :withheld?, withheld?),
         {{nodes, edges}, _actionable, _at} <-
           RequirementGraph.cached_graph_with_actionable(scope) do
      case selected(scope, copy, requested_number) do
        {:ok, story} ->
          story_or_project(story, nodes, edges, ctx, role, requested_number)

        {:refused, reason} ->
          result(:unavailable, nil, reason)

        :none ->
          from_copy(nodes, edges, ctx, role)
      end
    else
      _ -> result(:unavailable, nil, "This session has no working copy on this project.")
    end
  end

  # A story with nothing in it for this role does not hide the project.
  #
  # Only when the caller named no story. Asking *for* a story still answers
  # about that story or refuses — the rule below, and the bug it was written
  # for, are untouched.
  #
  # Admission asks bare, and that is what made this matter. A copy pointed at a
  # story answered every role "blocked" while the project chain was
  # unfinished — so the first thing anyone does on a new project, assign a
  # story, stopped the fleet dead with `list_agent_work` reporting "the graph
  # holds no work for its role" and nothing naming the story scope as the
  # reason. Measured on the math project 2026-09-22: four roles idle for an
  # hour over a ready `spex_boundary_ready`, which ran within seconds of the
  # story being cleared.
  #
  # The story still wins wherever it has work, so selecting one still steers
  # who does what. It stops being a blindfold, not a preference.
  #
  # The fallback is `project_level/5`, not `from_copy/4`, and the difference is
  # the whole of story 561. Widening to the copy offers *other stories'* work,
  # which is what "completion is local to the active story" forbids: a finished
  # story has to answer "complete" rather than quietly pulling its copy onto the
  # next one. Eight of 561's criteria say so, and they caught this within the
  # hour. Project-level requirements belong to no story at all, so offering them
  # takes nothing away from the active one.
  #
  # And only when a role asked. `my_role/2` answers a role for an agent and
  # `nil` for anyone else, so a role-less ask is a person asking about this
  # copy — that answer stays on the copy's story, which is criterion 3609: QA
  # fails, an issue is filed against the story, and the reply has to be "your
  # story is blocked on this" rather than "go triage issues". The issue needing
  # triage is that story's own. An agent asking what *it* should do is the case
  # that was broken, and it always names a role.
  defp story_or_project(story, nodes, edges, ctx, nil, nil),
    do: from_graph(story, nodes, edges, ctx, nil)

  defp story_or_project(story, nodes, edges, ctx, role, nil) do
    case from_graph(story, nodes, edges, ctx, role) do
      %{actionable: []} = story_scoped -> project_level(nodes, edges, ctx, role, story_scoped)
      story_scoped -> story_scoped
    end
  end

  defp story_or_project(story, nodes, edges, ctx, role, _requested),
    do: from_graph(story, nodes, edges, ctx, role)

  # Project-scope work, and nothing else, for a copy whose story holds none.
  #
  # `entity_type == "project"` is the filter that makes this safe to reach from
  # a story-scoped ask: those fourteen requirements — `architecture_designed`,
  # `spex_boundary_ready`, `issues_triaged`, `work_dispatched`, QA's journey
  # chain — are not in any story, so surfacing them cannot move a copy off the
  # one it is on. A story node or another story's component never passes it.
  #
  # With nothing at project level either, the story's own answer stands. It
  # already says complete, or blocked and why, and replacing that with a
  # project-shaped "nothing to do" would lose which story the copy is on.
  defp project_level(nodes, edges, ctx, role, story_scoped) do
    nodes
    |> actionable_nodes(edges, ctx, role)
    |> Enum.filter(&(&1.entity_type == "project"))
    |> project_result(story_scoped)
  end

  defp project_result([], story_scoped), do: story_scoped

  defp project_result(actionable, _story_scoped) do
    wave = next_wave(actionable)

    %{
      result(:ready, nil, "")
      | actionable: actionable,
        wave: wave,
        remaining: length(actionable) - length(wave)
    }
  end

  # The story this copy has selected, if it has selected one that is still
  # eligible.
  #
  # Three answers, not two, and the third is the whole of this. `:none` means
  # the copy chose nothing and is answered for the project — story 1005's rule,
  # and the fourteen project-level requirements that belong to no story depend
  # on it. `{:refused, why}` means the caller named a story that this copy
  # cannot answer for.
  #
  # Those were one answer until dogfooding separated them. A mismatched
  # `story_id` fell through to `:none` and handed back the entire project:
  # asking for story 802 while 1020 was active returned `# Story scope, Wave 1,
  # Remaining 33` — byte-identical to the answer for no selection at all. The
  # comment here already said that must not happen; only the code disagreed,
  # and it started disagreeing when `from_copy/5` widened to the whole project
  # and `:none` quietly acquired a second meaning.
  #
  # So the split is by whether the caller named a story, not by what the copy
  # holds. Asked bare, behaviour is unchanged. Asked for a story, the answer is
  # about that story or it is a refusal — never the project. `GetNextRequirement`
  # has always documented it that way: "an explicit story must agree with the
  # working copy's active assignment".
  defp selected(scope, copy, nil) do
    with id when not is_nil(id) <- copy.active_story_id,
         %{ready_for_dev: true} = story <- Stories.get_story(scope, id),
         true <- story.working_copy_id == copy.id do
      {:ok, story}
    else
      _ -> :none
    end
  end

  # The caller names a story by its number; the copy holds it by id.
  defp selected(scope, copy, requested_number) do
    active = copy.active_story_id && Stories.get_story(scope, copy.active_story_id)

    with %{} <- active,
         true <- to_string(requested_number) == to_string(active.number),
         true <- active.ready_for_dev == true,
         true <- active.working_copy_id == copy.id do
      {:ok, active}
    else
      _ -> {:refused, refusal(requested_number, active && active.number)}
    end
  end

  defp refusal(requested, nil),
    do:
      "This working copy has no active story, so it has nothing to answer for story " <>
        "#{requested}. Select it with `set_active_story` first."

  defp refusal(requested, active), do: refusal_for(to_string(requested), to_string(active))

  # Matched on the same binding twice: the ids agree, so the story the caller
  # named *is* the selection and something else made it ineligible.
  defp refusal_for(same, same),
    do:
      "Story #{same} is this copy's active story but is not available to it right now — " <>
        "it is not ready for development, or it has been assigned elsewhere."

  defp refusal_for(requested, active),
    do:
      "Story #{requested} is not this working copy's active story (#{active}). Asking for " <>
        "another story does not widen the answer; switch with `set_active_story`."

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
  #
  # And whether there is a graph at all. Zero requirements means zero
  # unsatisfied, and `Enum.all?/2` over nothing is true: Metric Flow, with 182
  # components, 53 stories and 27 failing tests, answered "All requirements
  # satisfied" because nothing had ever projected it. That sentence is what
  # decides whether an agent is started, so the empty graph gets its own.
  defp empty_reason([], _edges, _ctx), do: no_graph_reason()

  defp empty_reason(nodes, edges, ctx) do
    case graph_actionable(nodes, edges, ctx, nil) do
      [] ->
        "# All requirements satisfied\n\nNo actionable requirements remain."

      elsewhere ->
        "Nothing for this role right now. #{length(elsewhere)} actionable requirement(s) in " <>
          "this project belong to other roles — this is not a finished project. Select a " <>
          "story with set_active_story when one is ready."
    end
  end

  @doc """
  What a read is told when the graph holds no rows at all — not a finished
  project, and not a queue that belongs to someone else.
  """
  @spec no_graph_reason() :: String.t()
  def no_graph_reason do
    """
    # No requirement graph yet

    Nothing has been projected for this project: no requirement is satisfied or \
    unsatisfied, so this is not a finished project. The writers start on this read; \
    call `get_next_requirement` again. If this persists, the graph's writer is not \
    running — see `/dev/graph`.\
    """
  end

  defp actionable_nodes(nodes, edges, context, role) do
    nodes
    |> graph_actionable(edges, context, role)
    |> Enum.reject(Map.get(context, :withheld?, fn _ -> false end))
  end

  defp graph_actionable(nodes, edges, context, nil),
    do: RequirementGraph.actionable_from(nodes, edges, context)

  defp graph_actionable(nodes, edges, context, role),
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
      blocks_on_questions?(questions, role) ->
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

  # 56cf5697: this used to block every role unconditionally, which is right
  # for coding/QA — a story with a red card open is not ready to build or
  # test — and wrong for product, the one role that owns questions: it left
  # the block naming no actor, so nothing ever offered the work of clearing
  # it. Product still blocks here when the seal itself
  # (`three_amigos_complete`) is not yet satisfied — pre-seal questions
  # already block sealing via `BddRulesChecker`'s own gate, and there is
  # nothing product-specific to offer ahead of that.
  defp blocks_on_questions?(questions, role), do: questions != [] and role != :product

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
