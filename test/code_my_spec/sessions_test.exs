defmodule CodeMySpec.SessionsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  import CodeMySpec.SessionsFixtures

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "sessions_context_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    {:ok, env} = CodeMySpec.Environments.create(:local, working_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{env: env}
  end

  describe "create_session/2" do
    test "with valid data creates a session", %{env: env} do
      valid_attrs = %{
        status: :active,
        type: AgentTasks.ContextSpec,
        state: %{}
      }

      assert {:ok, %Session{} = session} = Sessions.create_session(env, valid_attrs)
      assert session.status == :active
      assert session.type == AgentTasks.ContextSpec
      assert session.state == %{}
    end

    test "with invalid data returns error changeset", %{env: env} do
      assert {:error, %Ecto.Changeset{}} = Sessions.create_session(env, %{type: nil})
    end
  end

  describe "get_session/2" do
    test "returns the session with given id", %{env: env} do
      session = session_fixture(env)
      assert {:ok, %Session{} = fetched} = Sessions.get_session(env, session.id)
      assert fetched.id == session.id
      assert fetched.status == session.status
      assert fetched.type == session.type
    end

    test "returns error when session doesn't exist", %{env: env} do
      assert {:error, :not_found} = Sessions.get_session(env, Ecto.UUID.generate())
    end
  end

  describe "list_sessions/1" do
    test "returns all sessions", %{env: env} do
      session1 = session_fixture(env)
      session2 = session_fixture(env, %{type: AgentTasks.ComponentSpec})

      assert {:ok, sessions} = Sessions.list_sessions(env)
      assert length(sessions) == 2

      ids = Enum.map(sessions, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([session1.id, session2.id])
    end

    test "returns empty list when no sessions exist", %{env: env} do
      assert {:ok, []} = Sessions.list_sessions(env)
    end
  end

  describe "update_session/2" do
    test "with valid data updates the session", %{env: env} do
      session = session_fixture(env)
      updated = %{session | status: :complete}

      assert {:ok, %Session{} = result} = Sessions.update_session(env, updated)
      assert result.status == :complete
    end
  end

  describe "delete_session/2" do
    test "removes the session", %{env: env} do
      session = session_fixture(env)
      assert :ok = Sessions.delete_session(env, session.id)
      assert {:error, :not_found} = Sessions.get_session(env, session.id)
    end
  end

  describe "clear_sessions/1" do
    test "removes all sessions", %{env: env} do
      session_fixture(env)
      session_fixture(env, %{type: AgentTasks.ComponentSpec})

      assert :ok = Sessions.clear_sessions(env)
      assert {:ok, []} = Sessions.list_sessions(env)
    end
  end
end
