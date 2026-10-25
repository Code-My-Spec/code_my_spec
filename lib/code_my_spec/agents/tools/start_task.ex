defmodule CodeMySpec.Agents.Tools.StartTask do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.Tools.TaskResponses, as: TasksMapper
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Analysis.FleetHolds
  alias CodeMySpec.Components
  alias CodeMySpec.Notifications
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.StoryRefs
  alias CodeMySpec.TaskOwner

  @impl true
  def name, do: "start_task"

  @impl true
  def description do
    """
    Start working on a requirement.

    Takes a requirement (`requirement_name` + `entity_type` + `entity_id`, or
    `requirement_name` + `module_name`, as `get_next_requirement` offers it),
    creates and activates a task on its owner in one step, and returns the work
    prompt.

    The owner is the agent on the connection when there is one, otherwise the
    Claude Code session whose `session_id` the PreToolUse hook injects. `agent_id`
    may also carry a sub-agent label, which owns tasks on the caller's session.

    If the owner already holds an open task for this requirement, it returns
    that task's prompt (resuming a blocked one whose blocker is resolved)
    without creating a duplicate.

    See knowledge/tools, "start_task".
    """
  end

  @impl true
  def params do
    %{
      module_name:
        {:meta, :string,
         [
           description:
             "Component module name (alternative to entity_id for component requirements)"
         ]},
      session_id: {:meta, :string, [description: "Injected by hook — do not set manually"]},
      agent_id:
        {:meta, :string, [description: "Your agent identifier — claims ownership of the task"]},
      story_number:
        {:meta, :integer,
         [
           description:
             "A story's number — the same as entity_type `story` with entity_id set to it"
         ]},
      entity_id:
        {:meta, :string,
         [
           description:
             "The entity that owns this requirement: a story's number, or a component's or project's id"
         ]},
      requirement_name:
        {:required,
         {:meta, :string,
          [description: "Name of the requirement (e.g., implementation_file, ready_for_qa)"]}},
      entity_type:
        {:required, {:meta, :string, [description: "Entity type: component, story, or project"]}},
      requirement_id:
        {:meta, :string,
         [description: "Deprecated: use requirement_name + entity_type + entity_id"]}
    }
  end

  @impl true
  def call(params, context) do
    # Who is calling comes off the connection, not the arguments:
    # `Plugs.AgentScope` has already checked it names an agent on this project.
    # An argument cannot change the authenticated owner.
    caller_agent_id = context[:agent_id]
    session_id = Map.get(params, :session_id)
    agent_id = Map.get(params, :agent_id) || caller_agent_id

    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, owner} <- resolve_owner(scope, session_id, caller_agent_id, agent_id),
         {:ok, requirement} <- resolve_requirement(scope, params, owner) do
      start_or_resume(scope, owner, requirement, agent_id, context)
    else
      {:error, reason} ->
        TasksMapper.error(reason)
    end
  end

  # Issue work is not in the requirement graph, so the offer is read through
  # `Agents.Work`, as `get_next_requirement` gave it.
  defp resolve_requirement(
         scope,
         %{requirement_name: name, entity_type: "issue", entity_id: id},
         owner
       )
       when is_binary(name) and is_binary(id) do
    role = if match?(%Agent{}, owner), do: owner.role, else: nil

    case Enum.find(
           Work.actionable(scope, role, owner, claim: true),
           &(&1.name == name and &1.entity_type == "issue" and to_string(&1.entity_id) == id)
         ) do
      nil -> {:error, "Requirement #{name} not found for issue #{id}"}
      node -> {:ok, node}
    end
  end

  defp resolve_requirement(
         scope,
         %{requirement_name: name, entity_type: type, entity_id: ref},
         owner
       )
       when is_binary(name) and is_binary(type) and is_binary(ref) do
    case StoryRefs.entity_id(scope, type, ref) do
      nil -> {:error, "Story #{ref} not found"}
      id -> resolve_from_graph(scope, name, type, id, owner, ref)
    end
  end

  defp resolve_requirement(scope, %{requirement_name: name, module_name: module_name}, owner)
       when is_binary(name) and is_binary(module_name) do
    case Components.get_component_by_module_name(scope, module_name) do
      nil -> {:error, "Component not found: #{module_name}"}
      component -> resolve_from_graph(scope, name, "component", component.id, owner, component.id)
    end
  end

  defp resolve_requirement(_scope, _params, _owner) do
    {:error,
     "Must provide requirement_name + entity_type + entity_id, or requirement_name + module_name"}
  end

  defp resolve_from_graph(scope, name, entity_type, entity_id, owner, entity_ref) do
    {{all_nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(scope)

    found =
      Enum.find(all_nodes, fn n ->
        n.name == name and n.entity_type == entity_type and to_string(n.entity_id) == entity_id
      end) || placed(scope, owner, name, entity_type, entity_id)

    case found do
      nil -> {:error, "Requirement #{name} not found for #{entity_type} #{entity_ref}"}
      node -> {:ok, node}
    end
  end

  # A story placed on another copy has no node here; its work is read at that
  # copy, as `get_next_requirement` offered it.
  defp placed(scope, %Agent{role: role}, name, "story", story_id),
    do: Requirements.placed_story_node(scope, role, name, story_id)

  defp placed(_scope, _owner, _name, _entity_type, _entity_id), do: nil

  # An agent we run owns its tasks; it fires no hooks, so it has no session.
  # Checked ahead of the session: when both arrive, the agent is the one asked
  # for its active task at the end of the turn.
  defp resolve_owner(scope, session_id, caller_agent_id, subject_agent_id)

  defp resolve_owner(scope, _session_id, caller, subject) when is_binary(caller) do
    if subject == caller do
      Agents.fetch_agent(scope, caller)
    else
      {:error, "Cannot start another agent's task. Choose work as the authenticated agent."}
    end
  end

  defp resolve_owner(scope, session_id, nil, subject) when is_binary(subject) do
    case Agents.fetch_agent(scope, subject) do
      {:ok, agent} -> {:ok, agent}
      _ -> resolve_session_owner(scope, session_id)
    end
  end

  defp resolve_owner(scope, session_id, _caller, _subject),
    do: resolve_session_owner(scope, session_id)

  # Every task is an agent's: a terminal Claude Code session is one, registered
  # by its SessionStart hook. One that never registered has no owner.
  defp resolve_session_owner(scope, session_id) do
    case Agents.fetch_owner(scope, nil, session_id) do
      {:ok, agent} -> {:ok, agent}
      {:error, :no_owner} -> {:error, Agents.no_owner_message()}
      {:error, _reason} -> {:error, "Agent not found in this project."}
    end
  end

  defp start_or_resume(scope, owner, requirement, agent_id, context) do
    # Match on entity too: sub-agents may hold the same requirement for
    # different components.
    entity_id = to_string(requirement.entity_id)
    existing = find_existing_task(owner, requirement, entity_id)

    case current_review_task(scope, owner, existing) do
      {:ok, owner, existing} ->
        handle_existing(existing, scope, owner, requirement, agent_id, context)

      {:error, reason} ->
        TasksMapper.error(reason)
    end
  end

  defp current_review_task(scope, owner, %{requirement_name: "qa_complete", issue_id: nil} = task) do
    case CodeMySpec.Qa.capture_story_review(owner_scope(scope, owner), owner, task) do
      {:ok, _} ->
        {:ok, owner, task}

      {:error, :qa_review_superseded} ->
        with {:ok, updated} <- TaskOwner.complete_task(scope, owner, task.id, :cancelled) do
          {:ok, updated, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_review_task(_scope, owner, task), do: {:ok, owner, task}

  defp find_existing_task(owner, requirement, entity_id) do
    Enum.find(TaskOwner.tasks(owner), fn t ->
      t.requirement_name == requirement.name and
        t.status in [:prepared, :active, :blocked] and
        matches_entity?(t, requirement.entity_type, entity_id)
    end)
  end

  defp not_held(scope) do
    case FleetHolds.active(scope) do
      nil -> :ok
      hold -> {:error, FleetHolds.refusal(hold)}
    end
  end

  defp handle_existing(nil, scope, owner, requirement, agent_id, context) do
    # Whose work it is first: a claim outside the caller's role, story or team
    # is refused for that, whatever state the work is in.
    with :ok <- role_may_claim(owner, requirement),
         :ok <- story_may_claim(scope, owner, requirement),
         :ok <- team_may_claim(scope, owner, requirement),
         :ok <- not_already_done(scope, owner, requirement),
         :ok <- qa_eligible_to_start(scope, owner, requirement),
         :ok <- prerequisites_met(scope, owner, requirement),
         # 783f3709: only a NEW claim reaches this clause (the `nil` match
         # above) -- resuming a task the owner already holds matches
         # `handle_existing/6` further down and never checks the hold.
         :ok <- not_held(scope) do
      create_and_activate(scope, owner, requirement, agent_id, context)
    else
      # 542e01e7: an answered blocker (or any other stale notice) can send an
      # agent here for a requirement that stopped being eligible before the
      # agent got around to it -- the task it was about is already gone
      # (cancelled, superseded, claimed elsewhere), so there is nothing to
      # resume or cancel, unlike the :blocked branch above. A bare
      # `TasksMapper.error(:requirement_not_eligible)` rendered as the raw
      # atom string with no way forward; this names the requirement and
      # points at `get_next_requirement`, the same disposition the resume
      # branch already gives.
      {:error, :requirement_not_eligible} ->
        TasksMapper.error(
          "#{requirement.name} for #{requirement.entity_type} #{entity_label(scope, requirement)} is " <>
            "not eligible work right now -- nothing was claimed. Call get_next_requirement " <>
            "for what is actionable now."
        )

      {:error, reason} ->
        TasksMapper.error(reason)
    end
  end

  defp handle_existing(%{status: :active} = task, scope, owner, _req, _agent_id, context) do
    return_prompt(owner, task, scope, context)
  end

  defp handle_existing(%{status: :prepared} = task, scope, owner, _req, agent_id, context) do
    case TaskOwner.activate_task(scope, owner, task.id, agent_id) do
      {:ok, _updated} ->
        return_prompt(owner, task, scope, context)

      {:error, reason} ->
        TasksMapper.error(claim_error(reason))
    end
  end

  defp handle_existing(
         %{status: :blocked, blocker_resolved_at: nil} = task,
         _scope,
         _owner,
         _req,
         _agent_id,
         _context
       ) do
    TasksMapper.error("Task #{task.id} is blocked; its blocker has not been resolved.")
  end

  defp handle_existing(%{status: :blocked} = task, scope, owner, req, _agent_id, context) do
    scope = owner_scope(scope, owner)

    with :ok <- eligible_to_resume(scope, owner, req),
         {:ok, updated} <- TaskOwner.resume_task(scope, owner, task.id) do
      # Read off the task as it was: resuming clears its blocker.
      return_prompt(
        owner,
        TaskOwner.find_task(updated, task.id),
        scope,
        context,
        answered_blocker(task)
      )
    else
      {:error, :active_task_exists} ->
        TasksMapper.error(
          "Cannot resume task #{task.id} beside your active task. Finish that one first; " <>
            "this one is offered back to you once it is done."
        )

      # f7a4b81e: a tap-out denial (or a withdrawn blocker) can tell an agent
      # to resume a task whose requirement has since stopped being eligible
      # -- something else claimed the work, or the project state moved on, in
      # the window between that notice and this call. A bare error here left
      # the task stuck blocked forever: nothing auto-clears it, and the agent
      # had no path forward except guessing to call cancel_task itself.
      # Cancelling it here, the moment resume turns out to be impossible, and
      # pointing at get_next_requirement is the consistent disposition this
      # issue's correction asked for, instead of instructing an impossible
      # resume and leaving the attempt stranded.
      {:error, :requirement_not_eligible} ->
        {:ok, _updated} = TaskOwner.complete_task(scope, owner, task.id, :cancelled)

        TasksMapper.error(
          "Task #{task.id} named #{req.name} for #{req.entity_type} #{entity_label(scope, req)}, which " <>
            "is no longer eligible work -- cancelled rather than left stuck blocked. " <>
            "Call get_next_requirement for what is actionable now."
        )

      {:error, reason} ->
        TasksMapper.error("Cannot resume task #{task.id}: #{inspect(reason)}")
    end
  end

  defp owner_scope(scope, %Agent{working_copy_id: id}),
    do: %{scope | active_working_copy_id: id}

  # A fresh claim is checked against the caller's role: work its role is not
  # offered is work nothing would hand it.  An agent
  # holding an active task passes here and is refused by `TaskOwner`, which is
  # the refusal it must act on first. Issue nodes already name their role.
  defp role_may_claim(%Agent{role: role}, %{entity_type: "issue", role: role}), do: :ok

  defp role_may_claim(%Agent{role: role} = agent, requirement) when not is_nil(role) do
    if RoleProfile.claims_any?(role) or Requirements.offered_to?(role, requirement.name) or
         Agent.active_task(agent),
       do: :ok,
       else: {:error, not_your_role(role, requirement)}
  end

  defp role_may_claim(_owner, _requirement), do: :ok

  defp not_your_role(role, requirement) do
    whose =
      case Map.get(requirement, :role) do
        nil -> "not #{role}'s"
        owner_role -> "#{owner_role}'s"
      end

    "`#{requirement.name}` is #{whose} work, and you are the #{role} agent, so you cannot " <>
      "start it. `get_next_requirement` lists the work your role is offered."
  end

  # An agent bound to a story claims only that story's work, as it is only
  # offered that. Story-level work on another story is `team_may_claim/3`'s
  # refusal; this covers project-level work and other stories' components.
  # Issue work has its own checks.
  defp story_may_claim(_scope, _owner, %{entity_type: "issue"}), do: :ok

  defp story_may_claim(scope, %Agent{} = agent, requirement) do
    case Work.bound_story_id(agent) do
      nil ->
        :ok

      _story_id when requirement.entity_type == "story" ->
        :ok

      story_id ->
        if Agent.active_task(agent) ||
             Requirements.story_work?(owner_scope(scope, agent), story_id, requirement),
           do: :ok,
           else: {:error, outside_active_story(scope, story_id, requirement)}
    end
  end

  defp story_may_claim(_scope, _owner, _requirement), do: :ok

  defp outside_active_story(scope, story_id, requirement) do
    number = with %{number: n} <- Stories.get_story(scope, story_id), do: n

    "`#{requirement.name}` (#{requirement.entity_type}) is not part of your team's active " <>
      "story #{number || story_id}. While a story is active you take only its work; " <>
      "`get_next_requirement` lists it."
  end

  # Work the graph still offers but that is already done is refused, and the
  # graph is refreshed so the offer clears. Issue work is skipped:
  # `Agents.IssueWork` only offers the stage still open.
  defp not_already_done(_scope, _owner, %{entity_type: "issue"}), do: :ok

  defp not_already_done(scope, owner, requirement) do
    if Requirements.satisfied_now?(scope, requirement) do
      :ok = Requirements.refresh_entity(scope, {requirement.entity_type, requirement.entity_id})
      close_stale_offer(scope, owner, requirement)

      {:error,
       "`#{requirement.name}` (#{requirement.entity_type} #{entity_label(scope, requirement)}) " <>
         "is already satisfied — there is nothing to do, and the offer of it is closed. " <>
         "`get_next_requirement` shows what is left."}
    else
      :ok
    end
  end

  # The claim reads what the offer does (5a0c4944): a team member names a story
  # requirement the graph is not offering it because a declared prerequisite is
  # unsatisfied, and the claim is refused, saying which. `story_promoted` was
  # claimed while QA ran, and only `evaluate_task`'s own check stopped it
  # afterwards. Work the agent is not offered for another reason is left to the
  # checks above and below; an agent already holding a task is refused by
  # `TaskOwner` first.
  # Only the stages that follow certification. The earlier requirements are
  # claimed in specs (2021, 1868) whose stories have an unmet prerequisite by
  # construction and no other way to hold work, so enforcing them here would
  # rewrite those fixtures; the late stages are where a premature claim costs
  # QA's or promotion's time.
  @late_stages ~w(ready_for_qa qa_complete story_promoted)

  defp prerequisites_met(
         scope,
         %Agent{role: role} = agent,
         %{entity_type: "story", name: name} = requirement
       )
       when role in [:coding, :qa] and name in @late_stages do
    if Agent.active_task(agent) || offered?(scope, agent, requirement) do
      :ok
    else
      refuse_unmet(scope, requirement, Requirements.unmet_prerequisites(scope, requirement))
    end
  end

  defp prerequisites_met(_scope, _owner, _requirement), do: :ok

  defp offered?(scope, agent, requirement) do
    scope
    |> owner_scope(agent)
    |> Work.claimable_work(agent)
    |> Enum.any?(
      &(&1.name == requirement.name and
          to_string(&1.entity_id) == to_string(requirement.entity_id))
    )
  end

  defp refuse_unmet(_scope, _requirement, []), do: :ok

  defp refuse_unmet(scope, requirement, unmet) do
    {:error,
     "`#{requirement.name}` (#{requirement.entity_type} #{entity_label(scope, requirement)}) " <>
       "is not open yet: it follows #{Enum.map_join(unmet, ", ", &"`#{&1}`")}, which " <>
       "#{if length(unmet) == 1, do: "is", else: "are"} not satisfied. " <>
       "`get_next_requirement` shows what is open now."}
  end

  # A story's own offer subject is keyed on its public number (the same key
  # Work.node_key/2 builds), not the database id `requirement.entity_id`
  # carries -- the same resolution `entity_label/2` below already needs for
  # the same reason.
  defp close_stale_offer(scope, %Agent{id: id}, %{entity_type: "story"} = requirement) do
    Offers.close_stale(id, "story:#{entity_label(scope, requirement)}:#{requirement.name}")
  end

  defp close_stale_offer(_scope, %Agent{id: id}, requirement),
    do:
      Offers.close_stale(
        id,
        "#{requirement.entity_type}:#{requirement.entity_id}:#{requirement.name}"
      )

  defp close_stale_offer(_scope, _owner, _requirement), do: :ok

  defp entity_label(scope, %{entity_type: "story", entity_id: id}) do
    case Stories.get_story(scope, id) do
      %{number: number} -> number
      _ -> id
    end
  end

  defp entity_label(_scope, %{entity_id: id}), do: id

  defp qa_eligible_to_start(
         scope,
         owner,
         %{entity_type: "story", name: "qa_complete"} = requirement
       ),
       do: eligible_to_resume(owner_scope(scope, owner), owner, requirement)

  defp qa_eligible_to_start(_scope, _owner, _requirement), do: :ok

  # An issue task's own eligibility is answered by `Work.actionable/3` as
  # usual — the issue-dispatch rules are exactly what should decide it.
  defp eligible_to_resume(scope, owner, %{entity_type: "issue"} = requirement) do
    resume_eligible?(Work.actionable(scope, resume_role(owner), owner), requirement)
  end

  # `Work.actionable/3` hides story-graph nodes while the owner holds an
  # issue, which would refuse a still-eligible story task.
  # `Work.story_actionable/3` answers without that, still respecting another
  # agent withholding the same work.
  defp eligible_to_resume(scope, owner, requirement) do
    resume_eligible?(Work.story_actionable(scope, resume_role(owner), owner), requirement)
  end

  defp resume_role(owner), do: if(match?(%Agent{}, owner), do: owner.role, else: nil)

  defp resume_eligible?(nodes, requirement) do
    eligible? =
      Enum.any?(nodes, fn node ->
        node.name == requirement.name and node.entity_type == requirement.entity_type and
          to_string(node.entity_id) == to_string(requirement.entity_id)
      end)

    if eligible?, do: :ok, else: {:error, :requirement_not_eligible}
  end

  # d2044280: a task handed back here is the same signal `Agents.Waiting`
  # already reads as "holding something, not idle" -- the moment a
  # task-less tap-out stops holding the agent. Retiring it here, rather
  # than waiting on a second decision, keeps the permission row from
  # outliving the thing it described.
  # A resumed task leads with the question that blocked it and the user's
  # answer (`answered`), whatever led the agent back to it.
  defp return_prompt(owner, task, scope, _context, answered \\ "") do
    Notifications.retire_resumed_tap_out(owner)
    prompt = answered <> generate_prompt(task, scope)
    TasksMapper.prompt_response(prompt, task)
  end

  defp answered_blocker(%{blocker_type: :question, blocker_id: id}) when is_binary(id) do
    case Notifications.answer_detail(id) do
      nil -> ""
      answer -> "This task was blocked on question #{id}. #{answer}\n\n"
    end
  end

  defp answered_blocker(_task), do: ""

  defp create_and_activate(scope, owner, requirement, agent_id, context) do
    task_attrs = build_task_attrs(scope, requirement, agent_id)
    owner = maybe_init_owner(scope, owner, requirement.satisfied_by)

    with {:ok, updated_owner} <- TaskOwner.add_task(scope, owner, task_attrs),
         task = TaskOwner.find_task(updated_owner, task_attrs.id),
         {:ok, task} <- review_new_task(scope, updated_owner, task) do
      return_prompt(owner, task, scope, context)
    else
      {:error, reason} -> TasksMapper.error(claim_error(reason))
    end
  end

  # A story QA task records what it reviews as it starts; one that cannot
  # (uncertified, untriaged) is not left holding the agent.
  defp review_new_task(scope, owner, %{requirement_name: "qa_complete", issue_id: nil} = task) do
    case CodeMySpec.Qa.capture_story_review(owner_scope(scope, owner), owner, task) do
      {:ok, _review} ->
        {:ok, task}

      {:error, reason} ->
        {:ok, _} = TaskOwner.complete_task(scope, owner, task.id, :cancelled)
        {:error, reason}
    end
  end

  defp review_new_task(_scope, _owner, task), do: {:ok, task}

  # A team member works its team's story (`Agents.claim_story/3`): another
  # story's work is refused while the team holds one, and with none the story
  # is assigned to the whole team before the task starts. An agent already
  # holding an active task is refused by `TaskOwner`, so it moves no team.
  defp team_may_claim(scope, %Agent{} = agent, %{
         entity_type: "issue",
         details: %{"story_id" => story_id}
       })
       when not is_nil(story_id) do
    if Agent.active_task(agent), do: :ok, else: claim_for_team(scope, agent, story_id)
  end

  defp team_may_claim(scope, %Agent{} = agent, %{entity_type: "story", entity_id: story_id}) do
    if Agent.active_task(agent), do: :ok, else: claim_for_team(scope, agent, story_id)
  end

  defp team_may_claim(_scope, _owner, _requirement), do: :ok

  defp claim_for_team(scope, agent, story_id) do
    case Agents.claim_story(scope, agent, story_id) do
      :ok -> :ok
      {:error, {:outside_team_story, held}} -> {:error, outside_team_story(scope, held)}
      {:error, reason} -> {:error, "Cannot take this story for your team: #{inspect(reason)}"}
    end
  end

  defp outside_team_story(scope, held) do
    number = with %{number: n} <- Stories.get_story(scope, held), do: n

    "Your team is on story #{number || held}, and sees it through together before taking " <>
      "another. `get_next_requirement` lists its work."
  end

  defp claim_error({:active_task_exists, task_id}) do
    "You have an active task #{task_id}. Complete, block, or cancel it before starting another task."
  end

  defp claim_error(reason), do: "Failed to create task: #{inspect(reason)}"

  defp build_task_attrs(scope, requirement, agent_id) do
    {component_id, component_module_name, story_id} = build_entity_refs(scope, requirement)

    %{
      id: Ecto.UUID.generate(),
      session_type: requirement.satisfied_by,
      requirement_name: requirement.name,
      project_id: scope.active_project_id,
      component_id: component_id,
      component_module_name: component_module_name,
      story_id: story_id,
      issue_id: issue_ref(requirement),
      execution_type: requirement.execution_type || :main_agent,
      validation_type: requirement.validation_type || :automatic,
      status: :active,
      # Microsecond resolution, so started_at lands strictly past any file
      # mtime synced earlier in the same request.
      started_at: DateTime.utc_now(),
      agent_id: agent_id
    }
  end

  defp build_entity_refs(scope, %{entity_type: "component", entity_id: id}) do
    comp = Components.get_component(scope, id)
    {id, comp && comp.module_name, nil}
  end

  defp build_entity_refs(_scope, %{entity_type: "issue", details: %{"story_id" => id}}),
    do: {nil, nil, id}

  defp build_entity_refs(_scope, %{entity_type: "story", entity_id: id}), do: {nil, nil, id}
  defp build_entity_refs(_scope, _req), do: {nil, nil, nil}

  defp issue_ref(%{entity_type: "issue", entity_id: id}), do: to_string(id)
  defp issue_ref(_req), do: nil

  # A task module that sets its agent up on claiming (`StartImplementation`
  # turning continuous mode on) exports `init_owner/2`.
  defp maybe_init_owner(scope, %Agent{} = agent, task_module) do
    if Code.ensure_loaded?(task_module) and function_exported?(task_module, :init_owner, 2) do
      {:ok, agent} = task_module.init_owner(scope, agent)
      agent
    else
      agent
    end
  end

  defp matches_entity?(task, "component", entity_id) do
    to_string(task.component_id) == entity_id
  end

  defp matches_entity?(task, "story", entity_id) do
    to_string(task.story_id) == entity_id
  end

  defp matches_entity?(task, "project", entity_id) do
    to_string(task.project_id) == entity_id
  end

  defp matches_entity?(task, "issue", entity_id) do
    to_string(task.issue_id) == entity_id
  end

  defp matches_entity?(_task, _type, _id), do: true

  defp generate_prompt(task, scope) do
    task_module = task.session_type

    if is_nil(task_module) do
      "No task module configured for this task."
    else
      prompt =
        case task_module.command(scope, task) do
          {:ok, text} -> text
          {:error, reason} -> "Error generating prompt: #{format_error_reason(reason)}"
        end

      prompt
    end
  rescue
    error -> "Error: #{inspect(error)}"
  end

  # Task modules may return `{:error, atom}` (terse code) or
  # `{:error, {atom, message}}` (terse code + agent-actionable
  # message). Prefer the message when present.
  defp format_error_reason(reason), do: CodeMySpec.AgentTasks.format_error(reason)
end
