defmodule CodeMySpec.Sessions do
  @moduledoc """
  Manages agent task sessions backed by the filesystem.

  Each session is a directory under `.code_my_spec/internal/sessions/{id}/`
  containing `session.json` and working files. All operations delegate to
  SessionsRepository for CRUD and SessionStack for evaluation.
  """

  alias CodeMySpec.Sessions.SessionsRepository
  alias CodeMySpec.Sessions.SessionStack

  defdelegate create_session(env, attrs), to: SessionsRepository
  defdelegate get_session(env, id), to: SessionsRepository
  defdelegate list_sessions(env), to: SessionsRepository
  defdelegate update_session(env, session), to: SessionsRepository
  defdelegate delete_session(env, id), to: SessionsRepository
  defdelegate clear_sessions(env), to: SessionsRepository
  defdelegate evaluate(env, opts \\ []), to: SessionStack
end
