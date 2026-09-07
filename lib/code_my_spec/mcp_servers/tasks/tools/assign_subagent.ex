defmodule CodeMySpec.McpServers.Tasks.Tools.AssignSubagent do
  @moduledoc """
  Assign a registered sub-agent to an open task (Story 704 / Rule 4).

  Atomically updates `Task.agent_id`: if the sub-agent currently owns a
  different task on this session, that task's `agent_id` is cleared and
  the target task's `agent_id` is set in the **same** `Repo.update` —
  no partial-failure window where the sub-agent ends up unassigned
  from their old task while not landing on the new one.

  Errors when:
  - the `agent_id` is not currently active in `session.subagents`
    (filtered through `Session.active_subagents/2`, so TTL-expired
    registrations are rejected the same way a fully unknown id is)
  - the `task_id` is not on the session
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  schema do
    field :session_id, :string, doc: "Injected by hook — do not set manually"

    field :agent_id, :string, required: true, doc: "Registered sub-agent id"

    field :task_id, :string, required: true, doc: "Target task id"
  end

  @impl true
  def execute(params, frame) do
    session_id = Map.get(params, :session_id)
    agent_id = Map.get(params, :agent_id)
    task_id = Map.get(params, :task_id)

    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, session} <- resolve_session(scope, session_id),
         :ok <- ensure_active(scope, session, agent_id),
         {:ok, target} <- ensure_task(session, task_id),
         {:ok, _updated} <- Sessions.reassign_agent(scope, session, task_id, agent_id) do
      msg =
        "Assigned sub-agent `#{agent_id}` to task `#{task_id}` " <>
          "(#{target.requirement_name || "—"}).\n\n" <> git_note()

      {:reply, Response.tool() |> Response.text(msg), frame}
    else
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("#{format_reason(reason)}"), frame}
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
  # through `StartTask`, the same reason `Validation.blocking_key/1` is. The
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
      {:error, "agent_id `#{agent_id}` is not an active registered sub-agent on this session"}
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
