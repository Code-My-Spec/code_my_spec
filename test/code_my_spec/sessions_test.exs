defmodule CodeMySpec.SessionsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Environments.Environment

  import CodeMySpec.SessionsFixtures

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "sessions_context_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a scope with an environment for testing
    scope = %Scope{
      environment: Environment.new(:local, tmp_dir)
    }

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{scope: scope}
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
    end

    test "with invalid data returns error changeset", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} = Sessions.create_session(scope, %{type: nil})
    end
  end

  describe "get_session/2" do
    test "returns the session with given id", %{scope: scope} do
      session = session_fixture(scope)
      assert {:ok, %Session{} = fetched} = Sessions.get_session(scope, session.id)
      assert fetched.id == session.id
      assert fetched.status == session.status
      assert fetched.type == session.type
    end

    test "returns error when session doesn't exist", %{scope: scope} do
      assert {:error, :not_found} = Sessions.get_session(scope, Ecto.UUID.generate())
    end
  end

  describe "list_sessions/1" do
    test "returns all sessions", %{scope: scope} do
      session1 = session_fixture(scope)
      session2 = session_fixture(scope, %{type: AgentTasks.ComponentSpec})

      assert {:ok, sessions} = Sessions.list_sessions(scope)
      assert length(sessions) == 2

      ids = Enum.map(sessions, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([session1.id, session2.id])
    end

    test "returns empty list when no sessions exist", %{scope: scope} do
      assert {:ok, []} = Sessions.list_sessions(scope)
    end
  end

  describe "update_session/2" do
    test "with valid data updates the session", %{scope: scope} do
      session = session_fixture(scope)
      updated = %{session | status: :complete}

      assert {:ok, %Session{} = result} = Sessions.update_session(scope, updated)
      assert result.status == :complete
    end
  end

  describe "delete_session/2" do
    test "removes the session", %{scope: scope} do
      session = session_fixture(scope)
      assert :ok = Sessions.delete_session(scope, session.id)
      assert {:error, :not_found} = Sessions.get_session(scope, session.id)
    end
  end

  describe "list_active_sessions/1" do
    test "returns sessions sorted by priority descending", %{scope: scope} do
      session_fixture(scope, %{type: AgentTasks.ContextSpec, priority: 1})
      session_fixture(scope, %{type: AgentTasks.ComponentSpec, priority: 10})

      assert {:ok, sessions} = Sessions.list_active_sessions(scope)
      assert length(sessions) == 2

      priorities = Enum.map(sessions, & &1.priority)
      assert priorities == [10, 1]
    end

    test "returns empty list when no sessions exist", %{scope: scope} do
      assert {:ok, []} = Sessions.list_active_sessions(scope)
    end
  end

  describe "clear_sessions/1" do
    test "removes all sessions", %{scope: scope} do
      session_fixture(scope)
      session_fixture(scope, %{type: AgentTasks.ComponentSpec})

      assert :ok = Sessions.clear_sessions(scope)
      assert {:ok, []} = Sessions.list_sessions(scope)
    end
  end
end
