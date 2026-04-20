defmodule CodeMySpec.SessionsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  import CodeMySpec.UsersFixtures
  import CodeMySpec.SessionsFixtures

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "create_session/2" do
    test "with valid data creates a session", %{scope: scope} do
      valid_attrs = %{
        status: :active,
        type: AgentTasks.ContextSpec,
        state: %{}
      }

      assert {:ok, %Session{} = session} = Sessions.create_session(scope, valid_attrs)
      assert session.status == :active
      assert session.type == AgentTasks.ContextSpec
      assert session.state == %{}
      assert session.project_id == scope.active_project_id
    end

    test "with invalid data returns error changeset", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} = Sessions.create_session(scope, %{status: nil})
    end
  end

  describe "get_session/2" do
    test "returns the session with given id", %{scope: scope} do
      session = session_fixture(scope)
      fetched = Sessions.get_session(scope, session.id)
      assert %Session{} = fetched
      assert fetched.id == session.id
      assert fetched.status == session.status
      assert fetched.type == session.type
    end

    test "returns nil when session doesn't exist", %{scope: scope} do
      assert Sessions.get_session(scope, Ecto.UUID.generate()) == nil
    end
  end

  describe "list_sessions/1" do
    test "returns all sessions", %{scope: scope} do
      session1 = session_fixture(scope)
      session2 = session_fixture(scope, %{type: AgentTasks.ComponentSpec})

      sessions = Sessions.list_sessions(scope)
      assert length(sessions) == 2

      ids = Enum.map(sessions, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([session1.id, session2.id])
    end

    test "returns empty list when no sessions exist", %{scope: scope} do
      assert Sessions.list_sessions(scope) == []
    end
  end

  describe "update_session/3" do
    test "with valid data updates the session", %{scope: scope} do
      session = session_fixture(scope)

      assert {:ok, %Session{} = result} =
               Sessions.update_session(scope, session, %{status: :complete})

      assert result.status == :complete
    end
  end

  describe "delete_session/2" do
    test "removes the session", %{scope: scope} do
      session = session_fixture(scope)
      assert {:ok, %Session{}} = Sessions.delete_session(scope, session.id)
      assert Sessions.get_session(scope, session.id) == nil
    end

    test "returns :not_found when session doesn't exist", %{scope: scope} do
      assert {:error, :not_found} = Sessions.delete_session(scope, Ecto.UUID.generate())
    end
  end

  describe "list_active_sessions/1" do
    test "returns only active sessions", %{scope: scope} do
      active = session_fixture(scope, %{status: :active})
      _complete = session_fixture(scope, %{status: :complete})

      sessions = Sessions.list_active_sessions(scope)
      assert length(sessions) == 1
      assert hd(sessions).id == active.id
    end

    test "returns empty list when no active sessions exist", %{scope: scope} do
      assert Sessions.list_active_sessions(scope) == []
    end
  end
end
