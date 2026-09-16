defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement do
  @moduledoc """
  Get the next actionable requirement for the project.

  Returns the single highest-priority requirement that is unsatisfied, has all
  prerequisites met, and has a task module that can satisfy it.

  This is a read-only discovery tool — use it as a shortcut when you just want
  the next thing to work on. Call `start_task` with the returned requirement_id
  to begin work.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Agents
  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Configurations
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Registry
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        sync_files(scope)

        # Resolve active sub-agents from the most recent session for this
        # project so the mapper can produce role-aware dispatch directives
        # (SendMessage to a live sub-agent vs. fresh Agent spawn).
        active_subagents = resolve_active_subagents(scope)

        actionable = RequirementGraph.next_actionable(scope)

        case of_my_kind(actionable, frame, scope) do
          [] ->
            {:reply, empty_response(scope, actionable, my_role(frame, scope)), frame}

          nodes ->
            {:reply, RequirementsMapper.next_requirements_response(nodes, active_subagents),
             frame}
        end

      {:error, _reason} ->
        # No project linked — return init checklist so the agent can bootstrap
        scope = build_init_scope(frame)
        {:ok, prompt} = Init.command(scope, %{})
        {:reply, RequirementsMapper.init_required_response(prompt), frame}
    end
  end

  # Sync files + components before computing the graph.
  # `embed: false` because this is a read path — re-embedding the framework
  # knowledge corpus and re-projecting hex docs on every `get_next_requirement`
  # is the wrong coupling. The `FileWatcherServer` boot pass + mix.lock-poll
  # already keep the embedding store fresh during a session. The explicit
  # `sync_project` MCP tool is the place for a manual full embed.
  #
  # `changed_paths` threaded through to `ComponentSync`, matching
  # `AgentTasks.Evaluator.sync_files/1` — without it, this scoped every single
  # call to a full, non-incremental resync of every component in the project
  # (1067 components, ~2100 raw UPDATEs, 7-25s) regardless of whether this
  # call's own scan found anything to change. Called once per agent loop
  # iteration, that was the dominant source of load on a large project, and it
  # also perpetually invalidated the requirements graph cache by marking every
  # component "changed" on every call.
  defp sync_files(%{cwd: nil}), do: :ok

  defp sync_files(%{cwd: cwd} = scope) do
    case FileSync.sync(scope, base_dir: cwd, embed: false) do
      {:ok, file_result} ->
        FileComponentSync.sync_from_files(scope,
          base_dir: cwd,
          changed_paths: file_result.changed_paths,
          removed_module_names: file_result.removed_module_names
        )

      {:error, _reason} ->
        :ok
    end
  end

  # Narrowed to the caller's own role — story 538's R10, which until now scoped
  # the *count* and not the tool.
  #
  # The menu told a product agent "7 requirements" — its own — and sent it here,
  # where it was handed the project's next actionable regardless of role. So it
  # picked up `story_issues_resolved` on a story it does not own, and a main
  # agent asked to organise epics was handed `bdd_specs_exist`. Both did exactly
  # what they were told; the two halves of the same sentence disagreed.
  #
  # The role comes off the connection (`Plugs.AgentScope`), so an agent does not
  # have to state it and cannot state somebody else's. A caller with no agent —
  # a Claude Code session — has no role and gets the whole graph, which is what
  # it had before and what a person driving by hand wants.
  #
  # Same source as `NodeRepository.actionable_count/2` deliberately: two
  # definitions of "my kind of work" would drift, and the drift shows up as a
  # count that disagrees with the list it is counting.
  # Computed for the role rather than filtered out of the project's answer.
  #
  # Filtering was the defect criterion 3491 names. The project's actionable set
  # has already had every node removed that sits downstream of *anyone's*
  # unfinished work, so narrowing it by name could only ever shorten a list
  # another role had already emptied. One untriaged issue left
  # `issues_triaged` — product's, and unclearable by coding — as the only
  # actionable node on the project, and a coding agent with red specs on its own
  # checkout was told "nothing for coding right now".
  #
  # `Requirements.actionable_for_role/2` asks the other question: what is
  # actionable *for this role*, treating another role's queue as somebody else's
  # problem rather than as a prerequisite. `44e450760` fixed that function; this
  # is the surface an agent actually calls, and it was still filtering.
  #
  # The two fall-throughs are kept exactly as they were: no agent means no role
  # (a Claude Code session driving by hand gets the whole graph), and a role
  # with no requirement kinds of its own gets the whole graph rather than
  # nothing.
  defp of_my_kind(nodes, frame, scope) do
    with role when not is_nil(role) <- my_role(frame, scope),
         names when names != [] <- Registry.requirement_names_for_role(role) do
      Requirements.actionable_for_role(scope, role)
    else
      _ -> nodes
    end
  end

  defp my_role(frame, scope) do
    with agent_id when is_binary(agent_id) <- frame.assigns[:agent_id],
         {:ok, %{role: role}} <- Agents.fetch_agent(scope, agent_id) do
      role
    else
      _ -> nil
    end
  end

  # Resolves the currently-active sub-agents for the most recent session
  # on this project. Returns a map of role string → agent_id, e.g.
  # %{"qa" => "a-qa-spex-1"}. Used by the mapper to choose between
  # SendMessage (live agent) and Agent spawn (no live agent for role).
  defp resolve_active_subagents(scope) do
    ttl = Configurations.get_or_create(scope).subagent_ttl_minutes

    case Sessions.list_active_sessions(scope) do
      [] ->
        %{}

      [session | _] ->
        session
        |> Session.active_subagents(ttl)
        |> Map.new(fn subagent -> {subagent.agent_name, subagent.agent_id} end)
    end
  end

  defp build_init_scope(frame) do
    working_dir = frame.assigns[:working_dir] || Validators.mcp_working_dir(frame)
    %{cwd: working_dir}
  end

  # Three states, not two, and the third is the one that reads as a finished
  # project when it is nothing of the sort.
  #
  # A coding agent on `49760b8b` was told "All requirements satisfied" while
  # three of them were unsatisfied. It was not wrong to stop — `issues_resolved`
  # is its own and sits behind `issues_triaged`, which is product's — but the
  # sentence it was given says the project is done, and the reader (a person, in
  # this case) has no way from here to tell that from a graph nobody has any
  # work in.
  #
  # So: nothing actionable for anyone is "all satisfied"; work that exists and
  # belongs to somebody else says whose it is. An agent that knows it is waiting
  # on product can say so instead of reporting completion.
  # Read, not recompute. This asked `compute_all/1` — a full graph, 4.4 seconds
  # on a 3,200-component project — to answer nothing more than "are there any
  # nodes at all", and it did it on the path an agent takes every time it asks
  # what to work on.
  #
  # The rows answer it. `cached_all/1` settles the watcher's queue first, so it
  # is current in the sense that matters, and a project with no rows is exactly
  # the "nothing has ever computed this" case the sync-required response is for.
  defp empty_response(scope, [], _role) do
    case Requirements.cached_all(scope) do
      {[], _computed_at} -> RequirementsMapper.sync_required_response()
      _ -> RequirementsMapper.all_satisfied_response()
    end
  end

  defp empty_response(_scope, actionable, role),
    do: RequirementsMapper.nothing_for_this_role_response(actionable, role)
end
