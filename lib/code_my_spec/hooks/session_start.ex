defmodule CodeMySpec.Hooks.SessionStart do
  @moduledoc """
  The SessionStart hook — find or create the session this agent is working in.

  Entirely a database operation, so there is nothing here that needs the
  machine the agent is running on. A harness with no database of its own can
  only forward it.
  """

  alias CodeMySpec.Sessions

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
        {200, %{session_id: session.id, status: to_string(session.status)}}

      {:error, %Ecto.Changeset{} = changeset} ->
        {422, %{error: inspect(changeset.errors)}}

      {:error, reason} ->
        {422, %{error: inspect(reason)}}
    end
  end
end
