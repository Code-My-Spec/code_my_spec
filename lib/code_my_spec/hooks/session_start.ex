defmodule CodeMySpec.Hooks.SessionStart do
  @moduledoc """
  The SessionStart hook — the agent a terminal session is (story 1122).

  Entirely a database operation, so there is nothing here that needs the
  machine the agent is running on. A harness with no database of its own can
  only forward it.
  """

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent

  @doc """
  Returns `{http_status, body}`.

  Unlike `CodeMySpec.Hooks.Stop`, which always answers 200 because "I could not
  decide" is itself a decision it renders, this one has genuine request errors —
  a missing session id is the caller's mistake and should read as one.
  """
  @spec handle(CodeMySpec.Users.Scope.t(), map()) :: {pos_integer(), map()}
  def handle(scope, params) do
    case Map.get(params, "session_id") do
      id when is_binary(id) and id != "" -> create(scope, id, params)
      _ -> {400, %{error: "session_id is required"}}
    end
  end

  defp create(scope, session_id, params) do
    messaging = params["messaging"]
    registered = Agents.register_terminal(scope, session_id, :main, engine(params))

    {200,
     %{}
     |> maybe_warn_co_occupant(scope, registered)
     |> introduce(registered, messaging)}
  end

  # The agent hears who it is: its id and the role it joined as, which it
  # settles with the person, and — when its harness found messages cannot
  # reach it directly — why they arrive when it stops (story 1123).
  # Registration failing leaves the session working.
  defp introduce(body, {:ok, agent}, messaging) do
    body
    |> Map.put(:agent_id, agent.id)
    |> Map.put(:hookSpecificOutput, %{
      hookEventName: "SessionStart",
      additionalContext:
        "You are agent #{agent.id} on this project, registered as its #{agent.role} agent. " <>
          "Main is the default; ask the person which role you should take (main, coding, " <>
          "qa or product); if it is not main, set it with `run_script`: " <>
          "`set_my_role({ role = \"coding\" })`." <>
          reached(messaging)
    })
  end

  # Never silent (issue 945c8a01): a session that did not join is the one thing
  # nobody would otherwise notice.
  defp introduce(body, {:error, reason}, _messaging) do
    Logger.warning(
      "[SessionStart] a terminal session did not register as an agent: #{inspect(reason)}"
    )

    body
  end

  defp engine(%{"engine" => "codex"}), do: :codex
  defp engine(_params), do: :claude_code

  defp reached(%{"delivery" => "stop_hook", "why" => why}),
    do:
      " Messages from main and your team cannot reach this session directly, because " <>
        why <> ", so they are handed to you when you stop."

  defp reached(_messaging), do: ""

  # Another agent is already working here, said to the agent rather than to a log.
  #
  # Warns into `server.log` would be the one place the agent is not looking.
  # `1f94a769` is that gap: two sessions in one worktree for hours, with
  # `git status` and `git log` both looking normal and both sessions committing
  # as the same author.
  #
  # Split by checkout, because the two cases are different hazards and take
  # different advice:
  #
  #   * **Same working copy** — one index and one HEAD. A `git add -- <path> &&
  #     git commit` commits the *index*, which may hold files the other session
  #     staged; a rebase moves the branch under a live session; autostash
  #     shares a stack.
  #
  #   * **Same project, different checkout** — no shared index, but shared task
  #     records.
  #
  # A warning, not a refusal: a desktop user and a sprite on one project may be
  # legitimate. What changes is only that the agent hears it.
  defp maybe_warn_co_occupant(body, scope, {:ok, %Agent{} = agent}) do
    case Agents.concurrent_terminal_agents(scope, agent) do
      [] -> body
      others -> Map.put(body, :systemMessage, co_occupancy_message(others, agent))
    end
  end

  defp maybe_warn_co_occupant(body, _scope, _registered), do: body

  defp co_occupancy_message(others, %Agent{working_copy_id: working_copy_id}) do
    {same_copy, elsewhere} = Enum.split_with(others, &(&1.working_copy_id == working_copy_id))

    [shared_index_warning(same_copy), shared_project_warning(elsewhere)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp shared_index_warning([]), do: nil

  defp shared_index_warning(agents) do
    "Another agent is working in this same checkout: #{names(agents)}. " <>
      "A worktree is one index and one HEAD, so `git add` and `git commit` act on a " <>
      "staging area you share — a commit can carry files the other session staged, and " <>
      "a rebase moves the branch under it. Stage explicit paths, check " <>
      "`git diff --cached` before every commit, and do not rebase or stash."
  end

  defp shared_project_warning([]), do: nil

  defp shared_project_warning(agents) do
    "Another agent is working on this project from a different checkout: " <>
      "#{names(agents)}. No shared index, but task records are shared — check that " <>
      "`start_task` and `evaluate_task` are acting on your own agent before " <>
      "assuming a task is yours."
  end

  defp names(agents), do: Enum.map_join(agents, ", ", & &1.engine_session_id)
end
