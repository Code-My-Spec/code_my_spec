defmodule CodeMySpec.SessionsTest do
  use CodeMySpec.DataCase

  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.AgentTasks

  describe "sessions" do
    alias CodeMySpec.Sessions.Session

    import CodeMySpec.UsersFixtures, only: [full_scope_fixture: 0]
    import CodeMySpec.SessionsFixtures

    @invalid_attrs %{status: nil, type: nil, state: nil, agent: nil, environment: nil}

    test "list_sessions/1 returns all scoped sessions" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      session = session_fixture(scope)
      other_session = session_fixture(other_scope)
      assert Sessions.list_sessions(scope) == [session]
      assert Sessions.list_sessions(other_scope) == [other_session]
    end

    test "get_session!/2 returns the session with given id" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      other_scope = full_scope_fixture()
      reloaded_session = Sessions.get_session!(scope, session.id)
      assert session.id == reloaded_session.id
      assert session.status == reloaded_session.status
      assert session.type == reloaded_session.type
      assert session.state == reloaded_session.state
      assert_raise Ecto.NoResultsError, fn -> Sessions.get_session!(other_scope, session.id) end
    end

    test "create_session/2 with valid data creates a session" do
      valid_attrs = %{
        status: :active,
        type: AgentTasks.ContextSpec,
        state: %{},
        agent: :claude_code,
        environment_type: :local
      }

      scope = full_scope_fixture()

      assert {:ok, %Session{} = session} = Sessions.create_session(scope, valid_attrs)
      assert session.status == :active
      assert session.type == AgentTasks.ContextSpec
      assert session.state == %{}
      assert session.agent == :claude_code
      assert session.environment_type == :local
      assert session.account_id == scope.active_account.id
    end

    test "create_session/2 with invalid data returns error changeset" do
      scope = full_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = Sessions.create_session(scope, @invalid_attrs)
    end

    test "update_session/3 with valid data updates the session" do
      scope = full_scope_fixture()
      session = session_fixture(scope)

      update_attrs = %{
        status: :complete,
        type: AgentTasks.ContextSpec,
        state: %{},
        agent: :claude_code,
        environment_type: :vscode
      }

      assert {:ok, %Session{} = session} = Sessions.update_session(scope, session, update_attrs)
      assert session.status == :complete
      assert session.type == AgentTasks.ContextSpec
      assert session.state == %{}
      assert session.agent == :claude_code
      assert session.environment_type == :vscode
    end

    test "update_session/3 with invalid scope raises" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      session = session_fixture(scope)

      assert_raise MatchError, fn ->
        Sessions.update_session(other_scope, session, %{})
      end
    end

    test "update_session/3 with invalid data returns error changeset" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      assert {:error, %Ecto.Changeset{}} = Sessions.update_session(scope, session, @invalid_attrs)
      reloaded_session = Sessions.get_session!(scope, session.id)
      assert session.id == reloaded_session.id
      assert session.status == reloaded_session.status
      assert session.type == reloaded_session.type
      assert session.state == reloaded_session.state
    end

    test "delete_session/2 deletes the session" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      assert {:ok, %Session{}} = Sessions.delete_session(scope, session)
      assert_raise Ecto.NoResultsError, fn -> Sessions.get_session!(scope, session.id) end
    end

    test "delete_session/2 with invalid scope raises" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      session = session_fixture(scope)
      assert_raise MatchError, fn -> Sessions.delete_session(other_scope, session) end
    end

    test "change_session/2 returns a session changeset" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      assert %Ecto.Changeset{} = Sessions.change_session(scope, session)
    end

    test "update_execution_mode/3 updates session execution mode" do
      scope = full_scope_fixture()
      session = session_fixture(scope, %{execution_mode: :manual})

      assert session.execution_mode == :manual

      assert {:ok, updated_session} = Sessions.update_execution_mode(scope, session.id, "auto")
      assert updated_session.execution_mode == :auto
      assert updated_session.id == session.id
    end

    test "update_execution_mode/3 with invalid mode returns error" do
      scope = full_scope_fixture()
      session = session_fixture(scope)

      assert {:error, %Ecto.Changeset{}} =
               Sessions.update_execution_mode(scope, session.id, "invalid")
    end

    test "update_execution_mode/3 with non-existent session returns error" do
      scope = full_scope_fixture()
      fake_uuid = "00000000-0000-0000-0000-000000000000"

      assert {:error, :session_not_found} =
               Sessions.update_execution_mode(scope, fake_uuid, "auto")
    end

    test "update_execution_mode/3 does not regenerate if no pending interaction" do
      scope = full_scope_fixture()
      session = session_fixture(scope, %{execution_mode: :manual})

      # No interactions, so no command to regenerate
      assert {:ok, updated_session} = Sessions.update_execution_mode(scope, session.id, "auto")
      assert updated_session.execution_mode == :auto
      assert updated_session.interactions == []
    end

    test "get_active_session_by_external_id/2 returns active session with matching external_id" do
      scope = full_scope_fixture()
      external_id = "claude-session-123"

      session =
        session_fixture(scope, %{
          external_conversation_id: external_id,
          status: :active
        })

      result = Sessions.get_active_session_by_external_id(scope, external_id)
      assert result.id == session.id
      assert result.external_conversation_id == external_id
    end

    test "get_active_session_by_external_id/2 returns nil when no matching session" do
      scope = full_scope_fixture()
      _session = session_fixture(scope, %{external_conversation_id: "other-id"})

      assert Sessions.get_active_session_by_external_id(scope, "nonexistent-id") == nil
    end

    test "get_active_session_by_external_id/2 returns nil when session is not active" do
      scope = full_scope_fixture()
      external_id = "claude-session-456"

      _session =
        session_fixture(scope, %{
          external_conversation_id: external_id,
          status: :complete
        })

      assert Sessions.get_active_session_by_external_id(scope, external_id) == nil
    end

    test "get_active_session_by_external_id/2 returns most recent when multiple sessions exist" do
      scope = full_scope_fixture()
      external_id = "claude-session-789"

      # Create first session
      older_session =
        session_fixture(scope, %{
          external_conversation_id: external_id,
          status: :active
        })

      # Backdate the older session's inserted_at to ensure ordering
      import Ecto.Query
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      CodeMySpec.Repo.update_all(
        from(s in Session, where: s.id == ^older_session.id),
        set: [inserted_at: past_time]
      )

      # Create second session with same external_id (will have current timestamp)
      newer_session =
        session_fixture(scope, %{
          external_conversation_id: external_id,
          status: :active
        })

      result = Sessions.get_active_session_by_external_id(scope, external_id)
      assert result.id == newer_session.id
      assert result.id != older_session.id
    end

    test "get_active_session_by_external_id/2 respects scope boundaries" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      external_id = "claude-session-shared"

      _session =
        session_fixture(scope, %{
          external_conversation_id: external_id,
          status: :active
        })

      # Other scope should not see this session
      assert Sessions.get_active_session_by_external_id(other_scope, external_id) == nil
    end
  end
end
