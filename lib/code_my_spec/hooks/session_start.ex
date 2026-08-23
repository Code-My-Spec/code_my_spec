defmodule CodeMySpec.Hooks.SessionStart do
  @moduledoc """
  The SessionStart hook — find or create the session this agent is working in.

  Entirely a database operation, so there is nothing here that needs the
  machine the agent is running on. A harness with no database of its own can
  only forward it.
  """

  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  @doc """
  Returns `{http_status, body}`.

  Unlike `CodeMySpec.Hooks.Stop`, which always answers 200 because "I could not
  decide" is itself a decision it renders, this one has genuine request errors —
  a missing session id is the caller's mistake and should read as one.
  """
  @spec handle(CodeMySpec.Users.Scope.t(), map()) :: {pos_integer(), map()}
  def handle(scope, params) do
    case Map.get(params, "session_id") do
      id when is_binary(id) and id != "" -> create(scope, id)
      _ -> {400, %{error: "session_id is required"}}
    end
  end

  defp create(scope, session_id) do
    case Sessions.find_or_create_session(scope, session_id) do
      {:ok, session} ->
        {200,
         %{session_id: session.id, status: to_string(session.status)}
         |> maybe_warn_co_occupant(scope, session)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {422, %{error: inspect(changeset.errors)}}

      {:error, reason} ->
        {422, %{error: inspect(reason)}}
    end
  end

  # Another agent is already working here, said to the agent rather than to a log.
  #
  # `Sessions.concurrent_sessions/2` has detected this all along and its
  # comment is right that "silently proceeding was the thing that hurt, not the
  # concurrency itself" — but it warns into `server.log`, which is the one place
  # the agent is not looking. `1f94a769` is that gap one level over: two
  # sessions in one worktree for hours, with `git status` and `git log` both
  # looking normal and both sessions committing as the same author.
  #
  # Split by harness, because the two cases are different hazards and take
  # different advice:
  #
  #   * **Same harness** — one working copy, so one index and one HEAD. A
  #     `git add -- <path> && git commit` commits the *index*, which may hold
  #     files the other session staged; a rebase moves the branch under a live
  #     session; autostash shares a stack. Measured in one morning: a commit
  #     carrying eight foreign files pushed under a message about one test
  #     file, and a push that shipped a commit the pusher never made and
  #     reported it verified.
  #
  #   * **Same project, different checkout** — no shared index, but shared task
  #     records. The case behind `concurrent_sessions/2` itself: a second agent
  #     whose MCP session had failed to register used the only session id it
  #     could find, which was the first agent's, so every `start_task` and
  #     `evaluate_task` it made was attributed elsewhere, including a task it
  #     cancelled there.
  #
  # A warning, not a refusal, for the reason already recorded there: a desktop
  # user and a sprite on one project may be legitimate, and refusing is a policy
  # call. What changes is only that the agent hears it.
  defp maybe_warn_co_occupant(body, scope, session) do
    case Sessions.concurrent_sessions(scope, session.external_conversation_id) do
      [] -> body
      others -> Map.put(body, :systemMessage, co_occupancy_message(others, session))
    end
  end

  defp co_occupancy_message(others, %Session{working_copy_id: working_copy_id}) do
    {same_copy, elsewhere} = Enum.split_with(others, &(&1.working_copy_id == working_copy_id))

    [shared_index_warning(same_copy), shared_project_warning(elsewhere)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp shared_index_warning([]), do: nil

  defp shared_index_warning(sessions) do
    "Another agent is working in this same checkout: #{names(sessions)}. " <>
      "A worktree is one index and one HEAD, so `git add` and `git commit` act on a " <>
      "staging area you share — a commit can carry files the other session staged, and " <>
      "a rebase moves the branch under it. Stage explicit paths, check " <>
      "`git diff --cached` before every commit, and do not rebase or stash."
  end

  defp shared_project_warning([]), do: nil

  defp shared_project_warning(sessions) do
    "Another agent is working on this project from a different checkout: " <>
      "#{names(sessions)}. No shared index, but task records are shared — check that " <>
      "`start_task` and `evaluate_task` are acting on your own session before " <>
      "assuming a task is yours."
  end

  defp names(sessions), do: Enum.map_join(sessions, ", ", & &1.external_conversation_id)
end
