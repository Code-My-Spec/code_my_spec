defmodule CodeMySpec.Requirements.StoryExecution do
  @moduledoc """
  The work offered to one working copy's explicitly selected story.

  Membership narrows the answer, never the graph used to check prerequisites.
  The project graph remains available for status and dependency diagnostics.
  """
  require Logger

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Requirements.{GraphWatcher, Preloader, Projection, Registry, RequirementGraph}
  alias CodeMySpec.{Stories, WorkingCopies}

  @completion_names ~w(component_linked three_amigos_complete questions_answered bdd_specs_exist ready_for_qa story_promoted qa_complete story_issues_triaged)

  # `withheld?` drops nodes the caller cannot claim — its own blocked task, or
  # another agent's at this checkout — before the wave is cut.
  #
  # `assignment` is whose story this is:
  #
  #   * `{:team, story_id, epic_id}` — the team's story, as `Agents.Work`
  #     resolves it. When that story is complete for the whole team the answer
  #     carries `:next_story`, the story the team takes next, so `Agents.Work`
  #     can move the whole team onto it.
  #   * `:copy` — the story the copy's team holds, read here. For callers below
  #     `Agents` that cannot resolve a team.
  #   * `{:bound, story_id, epic_id}` — an agent bound to its active story: as
  #     `{:team, …}`, but offered that story's work and nothing else, and not
  #     clamped by project-level prerequisites — see `seeds/1`.
  #   * `:project` — no story at all. The main agent's: story work happens on
  #     feature copies, never on main.
  def read(
        scope,
        role \\ nil,
        requested_number \\ nil,
        withheld? \\ fn _ -> false end,
        assignment \\ :copy
      ) do
    Process.delete(@laps)
    started = System.monotonic_time(:millisecond)

    with {:ok, copy} <- WorkingCopies.fetch(scope.active_working_copy_id),
         true <- copy.project_id == scope.active_project_id,
         :ok <- lap(:settle, fn -> GraphWatcher.settle(scope) end),
         {:ok, ctx} <- lap(:preload, fn -> Preloader.load(scope) end),
         ctx = Map.put(ctx, :withheld?, withheld?),
         {{nodes, edges}, _actionable, _at} <-
           lap(:graph, fn -> RequirementGraph.cached_graph_with_actionable(scope) end) do
      {nodes, edges, ctx} =
        lap(:placed, fn -> across_project(scope, role, nodes, edges, ctx) end)

      report_laps(role, System.monotonic_time(:millisecond) - started)

      case selected(scope, copy, requested_number, assignment) do
        {:ok, story} ->
          ctx = Map.put(ctx, :seeds, seeds(assignment))
          scoped = from_graph(story, nodes, edges, ctx, role)
          next = next_story(scoped, assignment, requested_number, nodes, edges, ctx)

          scoped
          |> story_or_project(assignment, {nodes, edges, ctx}, role, requested_number)
          |> Map.put(:next_story, next)

        {:refused, reason} ->
          result(:unavailable, nil, reason)

        {:unavailable, story} ->
          unavailable_bound(story, assignment)

        :none ->
          from_copy(nodes, edges, ctx, role)
      end
    else
      _ -> result(:unavailable, nil, "This session has no working copy on this project.")
    end
  end

  # c93e5fdc: a project-wide read (main's stop) once took 13.5s with nothing in
  # the logs to say where. The steps that can wait on something else -- the
  # projector draining, the preload, the graph, the placed stories -- are timed
  # as they run, and a read slower than a second says which one it spent it on.
  @slow_read_ms 1_000
  @laps :story_execution_laps

  defp lap(step, fun) do
    {us, result} = :timer.tc(fun)
    Process.put(@laps, [{step, div(us, 1000)} | Process.get(@laps, [])])
    result
  end

  defp report_laps(role, total_ms) do
    laps = @laps |> Process.delete() |> List.wrap() |> Enum.reverse()

    if total_ms >= @slow_read_ms do
      steps = Enum.map_join(laps, " ", fn {step, ms} -> "#{step}=#{ms}ms" end)

      Logger.warning(
        "[StoryExecution] slow read for #{inspect(role)} took #{total_ms}ms: #{steps}"
      )
    end
  end

  # Every story in the project, for a role that reads them wherever they are
  # placed (product, which lives on the main copy, whose vantage holds only
  # unassigned stories and its own). A placed story's nodes exist only at its
  # copy, so they are read there, not recomputed here.
  #
  # Only this role's own requirements are brought across, so a placed story
  # never offers it another role's work and a role-less read of this copy is
  # unchanged. The stories join `ctx.stories` for ordering by story priority.
  defp across_project(scope, role, nodes, edges, ctx) do
    case RoleProfile.story_vantage(role) do
      :project -> with_placed(Preloader.placed_elsewhere(scope), role, nodes, edges, ctx)
      :copy -> {nodes, edges, ctx}
    end
  end

  defp with_placed([], _role, nodes, edges, ctx), do: {nodes, edges, ctx}

  defp with_placed(stories, role, nodes, edges, ctx) do
    {placed_nodes, placed_edges} =
      Projection.placed(stories, Registry.requirement_names_for_role(role))

    {nodes ++ placed_nodes, edges ++ placed_edges, %{ctx | stories: ctx.stories ++ stories}}
  end

  # A story with nothing in it for this role does not hide the project: the
  # caller falls back to project-level work (`project_level/3`), never to other
  # stories' work, because completion is local to the active story. Only when a
  # role asked and named no story — a role-less ask is a person, who must hear
  # "your story is blocked on this". Never for a bound agent: it is offered its
  # story's work and nothing else, and a finished story stays `:complete` so
  # `Agents.Work` moves the team on.
  # See knowledge/requirements_graph/checkers, "Story execution".
  defp story_or_project(story_scoped, {:bound, _id, _epic}, _graph, _role, _requested),
    do: story_scoped

  defp story_or_project(story_scoped, _assignment, _graph, nil, nil), do: story_scoped

  defp story_or_project(%{actionable: []} = story_scoped, _assignment, graph, role, nil),
    do: project_level(graph, role, story_scoped)

  defp story_or_project(story_scoped, _assignment, _graph, _role, _requested),
    do: story_scoped

  # Which unsatisfied nodes hold the caller's work back. A bound agent is never
  # offered project-level work, so project-level prerequisites do not clamp its
  # story either (`qa_setup → component_linked` would hold every chain behind
  # work nobody bound can take), nor does another story's work: the seeds
  # narrow to its own nodes and its member components' (`story_seeds/3`).
  # Everyone else is clamped by every unsatisfied node.
  #
  # The same view decides completion: a project-level node upstream of a bound
  # story is not one of its blockers, or a story finished locally would never
  # read `:complete` and the team would never move on.
  defp seeds({:bound, _id, _epic}), do: :local
  defp seeds(_assignment), do: :all

  defp seeds_of(context), do: Map.get(context, :seeds, :all)

  # Narrowed to the story once its members are known: a bound story is held by
  # its own unsatisfied nodes and its subtree's, and by no other story's.
  defp story_seeds(story, ids, :local), do: {:story, story.id, ids}
  defp story_seeds(_story, _ids, seeds), do: seeds

  defp seed?(node, context), do: RequirementGraph.seed?(node, seeds_of(context))

  @doc """
  Whether `node` is `story`'s work: one of its own requirements or one of its
  member components' (`RequirementGraph.story_component_ids/2`). What an agent
  bound to `story` may claim.
  """
  @spec story_work?(map(), map(), map()) :: boolean()
  def story_work?(story, node, ctx),
    do: member?(node, story.id, RequirementGraph.story_component_ids(story, ctx))

  # A bound agent's story that cannot be read here: not ready for development,
  # or reserved for another checkout. Nothing is offered instead.
  defp unavailable_bound(nil, {:bound, id, _epic}),
    do:
      result(
        :blocked,
        nil,
        "Your team's active story (id #{id}) does not exist. Nothing outside it is " <>
          "offered until the team is given another with `set_active_story`."
      )

  defp unavailable_bound(story, _assignment),
    do:
      result(
        :blocked,
        story,
        "Your team's active story #{story.number} is not available on this working copy: " <>
          "it is not ready for development, or it is reserved elsewhere. Nothing outside " <>
          "it is offered until it is."
      )

  # Project-scope work, and nothing else, for a copy whose story holds none.
  #
  # `entity_type == "project"` makes this safe from a story-scoped ask: those
  # requirements are in no story, so they cannot move a copy off its own. With
  # nothing at project level either, the story's own answer stands.
  defp project_level({nodes, edges, ctx}, role, story_scoped) do
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
  # `:none`: the copy chose nothing and is answered for the project.
  # `{:refused, why}`: the caller named a story this copy cannot answer for —
  # asked for a story, the answer is about that story or a refusal, never the
  # project. `{:unavailable, story}`: a bound agent's ineligible story, since a
  # bound agent is not offered the project.
  #
  # The team's story must still be reserved for its checkout: the reservation
  # (`stories.working_copy_id`) is where the code lives, and the team's
  # `story_id` is which of the copy's stories it works.
  defp selected(scope, copy, nil, assignment) do
    id = assigned_id(copy, assignment)
    story = id && Stories.get_story(scope, id)

    cond do
      is_nil(id) -> :none
      eligible?(story, copy) -> {:ok, story}
      match?({:bound, _, _}, assignment) -> {:unavailable, story}
      true -> :none
    end
  end

  # The caller names a story by its number; the copy or the agent holds it by id.
  defp selected(scope, copy, requested_number, assignment) do
    id = assigned_id(copy, assignment)
    active = id && Stories.get_story(scope, id)

    with %{} <- active,
         true <- to_string(requested_number) == to_string(active.number),
         true <- active.ready_for_dev == true,
         true <- active.working_copy_id == copy.id do
      {:ok, active}
    else
      _ -> {:refused, refusal(requested_number, active && active.number)}
    end
  end

  defp assigned_id(copy, :copy), do: WorkingCopies.team_story_id(copy.id)
  defp assigned_id(_copy, {:team, story_id, _epic_id}), do: story_id
  defp assigned_id(_copy, {:bound, story_id, _epic_id}), do: story_id
  defp assigned_id(_copy, :project), do: nil

  defp eligible?(%{ready_for_dev: true, working_copy_id: id}, %{id: id}), do: true
  defp eligible?(_story, _copy), do: false

  # The story a team whose story is complete takes next.
  #
  # Candidates are the stories this copy can work — ready for development,
  # reserved here or unassigned, which is what `ctx.stories` already holds —
  # in the epic when the team has one, in the graph's own story order
  # (priority, then age), and not already complete. Nil when nothing is
  # eligible: the team stays "complete".
  defp next_story(
         %{status: :complete, story: current},
         {team, _id, epic_id},
         nil,
         nodes,
         edges,
         ctx
       )
       when team in [:team, :bound] do
    ctx.stories
    |> Enum.filter(&(&1.id != current.id and is_nil(&1.retired_at) and in_epic?(&1, epic_id)))
    |> Enum.sort_by(&{&1.priority || 999, age(&1.inserted_at)})
    |> Enum.find(&(from_graph(&1, nodes, edges, ctx, nil).status != :complete))
  end

  defp next_story(_scoped, _assignment, _requested, _nodes, _edges, _ctx), do: nil

  defp age(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp age(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> age()
  defp age(_at), do: 0

  defp in_epic?(_story, nil), do: true
  defp in_epic?(story, epic_id), do: story.epic_id == epic_id

  defp refusal(requested, nil),
    do:
      "This working copy's team has no active story, so it has nothing to answer for " <>
        "story #{requested}. Select it with `set_active_story` first."

  defp refusal(requested, active),
    do: refusal_for(to_string(requested), to_string(active), "this working copy's team's")

  # Matched on the same binding twice: the ids agree, so the story the caller
  # named *is* the selection and something else made it ineligible.
  defp refusal_for(same, same, holder),
    do:
      "Story #{same} is #{holder} active story but is not available right now — " <>
        "it is not ready for development, or it has been assigned elsewhere."

  defp refusal_for(requested, active, holder),
    do:
      "Story #{requested} is not #{holder} active story (#{active}). Asking for " <>
        "another story does not widen the answer; switch with `set_active_story`."

  # No story selected, which is not the same as nothing to do: the copy is
  # answered for the project, so project-level work and released, unassigned
  # stories reach an idle agent.
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

  # Nothing for this role: a finished project, somebody else's queue, or no
  # graph at all — three different sentences, because this one decides whether
  # an agent is started. Asked of the actionable set, not the unsatisfied one,
  # so an agent with nothing actionable may stop.
  # See knowledge/requirements_graph/checkers, "Story execution".
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
    do: RequirementGraph.actionable_for_role_from(nodes, edges, context, role, seeds_of(context))

  @doc false
  def from_graph(story, nodes, edges, ctx, role) do
    nodes = Enum.sort_by(nodes, &{&1.entity_name || "", &1.name, to_string(&1.entity_id)})
    ids = RequirementGraph.story_component_ids(story, ctx)
    local = Enum.filter(nodes, &member?(&1, story.id, ids))
    questions = Enum.filter(Map.get(ctx.questions_by_story, story.id, []), &(&1.status == :open))
    story_nodes = Enum.filter(local, &(&1.entity_type == "story"))
    present = MapSet.new(story_nodes, & &1.name)
    missing = Enum.reject(@completion_names, &MapSet.member?(present, &1))

    context =
      Map.merge(ctx, %{
        stories: [story],
        execution_component_ids: ids,
        seeds: story_seeds(story, ids, seeds_of(ctx))
      })

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
        blockers = nodes |> blocking_nodes(edges, local) |> Enum.filter(&seed?(&1, context))

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

  # An open question blocks roles that build or test (`RoleProfile.questions_block?`),
  # not product, which owns questions and must be offered the work of clearing
  # them. Product's own open questions hold it through `Agents.Waiting`.
  defp blocks_on_questions?(questions, role),
    do: questions != [] and RoleProfile.questions_block?(role)

  defp member?(%{entity_type: "story", entity_id: id, name: name}, story_id, _ids),
    do: to_string(id) == to_string(story_id) and name in @completion_names

  defp member?(%{entity_type: "issue", details: %{"story_id" => id}}, story_id, _ids),
    do: to_string(id) == to_string(story_id)

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
