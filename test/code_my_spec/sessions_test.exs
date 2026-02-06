defmodule CodeMySpec.SessionsTest do
  use CodeMySpec.DataCase

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Sessions

  describe "sessions" do
    alias CodeMySpec.Sessions.Session

    import CodeMySpec.UsersFixtures, only: [full_scope_fixture: 0]
    import CodeMySpec.SessionsFixtures

    @invalid_attrs %{status: nil, type: nil, state: nil, agent: nil, environment: nil}

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

    test "get_session/2 returns the session with given id" do
      scope = full_scope_fixture()
      session = session_fixture(scope)
      reloaded_session = Sessions.get_session(scope, session.id)
      assert session.id == reloaded_session.id
      assert session.status == reloaded_session.status
      assert session.type == reloaded_session.type
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
      reloaded_session = Sessions.get_session(scope, session.id)
      assert session.id == reloaded_session.id
      assert session.status == reloaded_session.status
      assert session.type == reloaded_session.type
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

      older_session =
        session_fixture(scope, %{
          external_conversation_id: external_id,
          status: :active
        })

      import Ecto.Query
      past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      CodeMySpec.Repo.update_all(
        from(s in Session, where: s.id == ^older_session.id),
        set: [inserted_at: past_time]
      )

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

      assert Sessions.get_active_session_by_external_id(other_scope, external_id) == nil
    end
  end
end
