defmodule CodeMySpec.Sessions do
  @moduledoc """
  Manages agent task sessions backed by the filesystem.

  Each session is a directory under `.code_my_spec/sessions/{id}/`
  containing `session.json` and working files. All CRUD operations extract
  `scope.environment` and delegate to SessionsRepository.
  """

  alias CodeMySpec.Sessions.SessionsRepository
  alias CodeMySpec.Sessions.SessionStack
  alias CodeMySpec.Users.Scope

  def create_session(%Scope{} = scope, attrs) do
    SessionsRepository.create_session(scope.environment, attrs)
  end

  def get_session(%Scope{} = scope, id) do
    SessionsRepository.get_session(scope.environment, id)
  end

  def list_sessions(%Scope{} = scope) do
    SessionsRepository.list_sessions(scope.environment)
  end

  def update_session(%Scope{} = scope, session) do
    SessionsRepository.update_session(scope.environment, session)
  end

  def delete_session(%Scope{} = scope, id) do
    SessionsRepository.delete_session(scope.environment, id)
  end

  def clear_sessions(%Scope{} = scope) do
    SessionsRepository.clear_sessions(scope.environment)
  end

  def list_active_sessions(%Scope{} = scope) do
    SessionStack.list_active(scope.environment)
  end
end
