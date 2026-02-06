defmodule CodeMySpec.Sessions do
  @moduledoc """
  The Sessions context.

  Currently provides DB-backed session CRUD used by StartAgentTask and
  EvaluateAgentTask. Being replaced by filesystem-based SessionStack.
  """

  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope

  import Ecto.Query, warn: false

  def get_session(%Scope{} = scope, id) do
    Session
    |> where([s], s.project_id == ^scope.active_project_id)
    |> where([s], s.user_id == ^scope.user.id)
    |> preload([
      :project,
      :component,
      [component: :parent_component],
      [child_sessions: [component: :project]]
    ])
    |> Repo.get(id)
  end

  def get_active_session_by_external_id(%Scope{} = scope, external_id) do
    Session
    |> where([s], s.external_conversation_id == ^external_id)
    |> where([s], s.status == :active)
    |> where([s], s.project_id == ^scope.active_project_id)
    |> where([s], s.user_id == ^scope.user.id)
    |> order_by([s], desc: s.inserted_at)
    |> limit(1)
    |> preload([
      :project,
      :component,
      [component: :parent_component],
      [child_sessions: [component: :project]]
    ])
    |> Repo.one()
  end

  def create_session(%Scope{} = scope, attrs) do
    %Session{}
    |> Session.changeset(attrs, scope)
    |> Repo.insert()
  end

  def update_session(%Scope{} = scope, %Session{} = session, attrs) do
    true = session.account_id == scope.active_account_id
    true = session.user_id == scope.user.id

    session
    |> Session.changeset(attrs, scope)
    |> Repo.update()
  end
end
