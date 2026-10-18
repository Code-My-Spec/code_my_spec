defmodule CodeMySpec.Agents.Tools.AssignSubagent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Configurations
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  @impl true
  def name, do: "assign_subagent"

  @impl true
  def description do
    """
    Assign a registered sub-agent to an open task (Story 704 / Rule 4).

    Atomically updates `Task.agent_id`: if the sub-agent currently owns a
    different task on this session, that task's `agent_id` is cleared and
    the target task's `agent_id` is set in the **same** `Repo.update` —
    no partial-failure window where the sub-agent ends up unassigned
    from their old task while not landing on the new one.

    `agent_id` is the Task tool's own result from spawning that sub-agent,
    not something to go look up — 50ddc827: `list_session_subagents` (the
    tool that *would* answer "who is registered") is not every role's to
    call, and the id is already yours from the spawn, every time.

    Errors when:
    - the `agent_id` is not currently active in `session.subagents`
      (filtered through `Session.active_subagents/2`, so TTL-expired
      registrations are rejected the same way a fully unknown id is)
    - the `task_id` is not on the session
    """
  end

  @impl true
  def params do
    %{
      session_id: {:meta, :string, [description: "Injected by hook — do not set manually"]},
      agent_id:
        {:required,
         {:meta, :string,
          [
            description:
              "The sub-agent's id, from the Task tool's own result when you spawned it " <>
                "— not something to look up elsewhere"
          ]}},
      task_id: {:required, {:meta, :string, [description: "Target task id"]}}
    }
  end

  @impl true
  def call(params, context) do
    session_id = Map.get(params, :session_id)
    agent_id = Map.get(params, :agent_id)
    task_id = Map.get(params, :task_id)

    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, session} <- resolve_session(scope, session_id),
         :ok <- ensure_active(scope, session, agent_id),
         {:ok, target} <- ensure_task(session, task_id),
         {:ok, _updated} <- Sessions.reassign_agent(scope, session, task_id, agent_id) do
      msg =
        "Assigned sub-agent `#{agent_id}` to task `#{task_id}` " <>
          "(#{target.requirement_name || "—"}).\n\n" <> git_note()

      {:ok, msg}
    else
      {:error, reason} ->
        {:error, "#{format_reason(reason)}"}
    end
  end

  # Said at assignment time, because that is when the prompt gets written.
  #
  # `PreToolUse` denies every mutating git subcommand to a sub-agent — b5e305fc,
  # where a wandering QA sub-agent ran `git revert` under the engineer's
  # identity and silently destroyed a fix. The guard is right and stays.
  #
  # What it could not do is reach the agent writing the assignment. 461ff38b:
  # a fix-* sub-agent was handed a prompt with detailed commit-and-push
  # instructions across three repos and a "Git safety" section, did all the
  # work, verified it, and then discovered at the first `git add` that none of
  # it was followable. It had to hand the diffs back and report the assignment
  # incomplete — and the assigning agent had no way to know, since the
  # restriction only announced itself in a refusal the assigner never sees.
  @doc false
  # Public only so the wording can be asserted without standing up a task
  # through `StartTask`. The
  # wiring is covered by story 704's spex, which run this tool for real.
  @spec git_note() :: String.t()
  def git_note do
    "Sub-agents cannot commit. `PreToolUse` allows read-only git only, so do not " <>
      "write commit, push, rebase or stash steps into this task's prompt — the " <>
      "sub-agent will do the work and then be unable to follow them. It hands " <>
      "finished work back as file edits in the working copy; committing stays with " <>
      "you."
  end

  defp resolve_session(scope, session_id) when is_binary(session_id) and session_id != "" do
    case Sessions.get_by_external_id(scope, session_id) do
      nil -> {:error, "Session not found: #{session_id}"}
      session -> {:ok, session}
    end
  end

  defp resolve_session(_scope, _),
    do:
      {:error,
       "No session_id and no agent id on this call, so there is nothing to act on.\n\n" <>
         "If you are Claude Code: `register_session` with this conversation's id " <>
         "(CLAUDE_SESSION_ID) creates it on this server.\n\n" <>
         "If you are an agent we run: your id travels on the connection and you " <>
         "cannot supply it — this is a harness fault, not something to retry or " <>
         "ask a person about. Report it with `create_issue` and carry on."}

  defp ensure_active(scope, session, agent_id) do
    ttl = Configurations.get_or_create(scope).subagent_ttl_minutes

    if Enum.any?(Session.active_subagents(session, ttl), &(&1.agent_id == agent_id)) do
      :ok
    else
      {:error,
       "agent_id `#{agent_id}` is not an active registered sub-agent on this session — " <>
         "it should be the id the Task tool handed back when you spawned it (or that " <>
         "registration has since expired past its TTL). There is no lookup to retry " <>
         "against; an id you did not get from your own spawn is not yours to assign."}
    end
  end

  defp ensure_task(session, task_id) do
    case Session.find_task(session, task_id) do
      nil -> {:error, "Task not found: #{task_id}"}
      task -> {:ok, task}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
