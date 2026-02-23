defmodule CodeMySpec.Sessions.SessionsRepositoryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Sessions.Session
  alias CodeMySpec.Sessions.SessionsRepository

  @sessions_dir ".code_my_spec/sessions"
  @completed_sessions_dir ".code_my_spec/sessions/completed"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "sessions_repo_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    {:ok, env} = CodeMySpec.Environments.create(:local, working_dir: tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{env: env, tmp_dir: tmp_dir}
  end

  describe "create_session/2" do
    test "creates session directory and writes session.json", %{env: env, tmp_dir: tmp_dir} do
      attrs = %{
        type: AgentTasks.ComponentSpec,
        priority: 1,
        component_module_name: "MyApp.MyComponent"
      }

      assert {:ok, %Session{} = session} = SessionsRepository.create_session(env, attrs)

      # Verify directory exists
      session_dir = Path.join([tmp_dir, @sessions_dir, session.id])
      assert File.dir?(session_dir)

      # Verify session.json exists and contains valid data
      session_file = Path.join(session_dir, "session.json")
      assert File.exists?(session_file)

      # Verify content is valid JSON
      json_content = File.read!(session_file)
      assert {:ok, decoded} = Jason.decode(json_content)

      # Verify fields
      assert decoded["type"] == "ComponentSpec"
      assert decoded["priority"] == 1
      assert decoded["component_module_name"] == "MyApp.MyComponent"
      assert decoded["status"] == "active"
    end

    test "generates UUID when id not provided", %{env: env} do
      attrs = %{
        type: AgentTasks.ComponentSpec,
        priority: 1
      }

      assert {:ok, %Session{} = session} = SessionsRepository.create_session(env, attrs)

      # Verify id is a valid UUID
      assert is_binary(session.id)
      assert String.length(session.id) == 36

      assert String.match?(
               session.id,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
             )
    end

    test "returns error for invalid attrs (missing type)", %{env: env} do
      attrs = %{priority: 1}

      assert {:error, changeset} = SessionsRepository.create_session(env, attrs)
      assert %Ecto.Changeset{} = changeset
      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "session.json is valid JSON that roundtrips through from_json", %{
      env: env,
      tmp_dir: tmp_dir
    } do
      attrs = %{
        type: AgentTasks.ComponentTest,
        priority: 2,
        component_module_name: "MyApp.TestComponent",
        status: :active,
        state: %{"key" => "value"}
      }

      assert {:ok, %Session{} = session} = SessionsRepository.create_session(env, attrs)

      # Read the JSON file
      session_file = Path.join([tmp_dir, @sessions_dir, session.id, "session.json"])
      json_content = File.read!(session_file)
      {:ok, decoded} = Jason.decode(json_content)

      # Roundtrip through from_json
      assert {:ok, %Session{} = roundtripped} = Session.from_json(decoded)

      # Verify all fields match
      assert roundtripped.id == session.id
      assert roundtripped.type == session.type
      assert roundtripped.priority == session.priority
      assert roundtripped.component_module_name == session.component_module_name
      assert roundtripped.status == session.status
      assert roundtripped.state == session.state
    end
  end

  describe "get_session/2" do
    test "returns session struct for existing session", %{env: env} do
      attrs = %{
        type: AgentTasks.ComponentSpec,
        priority: 1,
        component_module_name: "MyApp.Component"
      }

      {:ok, created_session} = SessionsRepository.create_session(env, attrs)

      assert {:ok, %Session{} = fetched_session} =
               SessionsRepository.get_session(env, created_session.id)

      assert fetched_session.id == created_session.id
      assert fetched_session.type == created_session.type
      assert fetched_session.priority == created_session.priority
      assert fetched_session.component_module_name == created_session.component_module_name
    end

    test "returns {:error, :not_found} when directory doesn't exist", %{env: env} do
      non_existent_id = Ecto.UUID.generate()

      assert {:error, :not_found} = SessionsRepository.get_session(env, non_existent_id)
    end

    test "returns {:error, :not_found} when session.json is missing", %{
      env: env,
      tmp_dir: tmp_dir
    } do
      # Create directory but don't create session.json
      session_id = Ecto.UUID.generate()
      session_dir = Path.join([tmp_dir, @sessions_dir, session_id])
      File.mkdir_p!(session_dir)

      assert {:error, :not_found} = SessionsRepository.get_session(env, session_id)
    end

    test "finds session in completed directory", %{env: env} do
      {:ok, session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1
        })

      # Move to completed via update
      SessionsRepository.update_session(env, %{session | status: :complete})

      # get_session should still find it
      assert {:ok, %Session{} = fetched} = SessionsRepository.get_session(env, session.id)
      assert fetched.id == session.id
      assert fetched.status == :complete
    end
  end

  describe "list_sessions/1" do
    test "returns all sessions as structs", %{env: env} do
      # Create multiple sessions
      {:ok, session1} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1
        })

      {:ok, session2} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentTest,
          priority: 2
        })

      {:ok, session3} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentCode,
          priority: 3
        })

      assert {:ok, sessions} = SessionsRepository.list_sessions(env)

      assert length(sessions) == 3
      session_ids = Enum.map(sessions, & &1.id) |> Enum.sort()
      expected_ids = [session1.id, session2.id, session3.id] |> Enum.sort()
      assert session_ids == expected_ids
    end

    test "returns empty list when sessions directory is empty", %{env: env, tmp_dir: tmp_dir} do
      # Create empty sessions directory
      sessions_dir = Path.join(tmp_dir, @sessions_dir)
      File.mkdir_p!(sessions_dir)

      assert {:ok, sessions} = SessionsRepository.list_sessions(env)
      assert sessions == []
    end

    test "returns empty list when sessions directory is missing", %{env: env} do
      assert {:ok, sessions} = SessionsRepository.list_sessions(env)
      assert sessions == []
    end

    test "does not include completed sessions", %{env: env} do
      {:ok, active_session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1
        })

      {:ok, completed_session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentTest,
          priority: 2
        })

      # Complete one session
      SessionsRepository.update_session(env, %{completed_session | status: :complete})

      assert {:ok, sessions} = SessionsRepository.list_sessions(env)
      assert length(sessions) == 1
      assert hd(sessions).id == active_session.id
    end

    test "skips directories with invalid session.json", %{env: env, tmp_dir: tmp_dir} do
      # Create one valid session
      {:ok, valid_session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1
        })

      # Create directory with invalid JSON
      invalid_id = Ecto.UUID.generate()
      invalid_dir = Path.join([tmp_dir, @sessions_dir, invalid_id])
      File.mkdir_p!(invalid_dir)
      File.write!(Path.join(invalid_dir, "session.json"), "{invalid json}")

      # Create directory with missing type field
      missing_type_id = Ecto.UUID.generate()
      missing_type_dir = Path.join([tmp_dir, @sessions_dir, missing_type_id])
      File.mkdir_p!(missing_type_dir)

      File.write!(
        Path.join(missing_type_dir, "session.json"),
        Jason.encode!(%{"id" => missing_type_id, "priority" => 1})
      )

      assert {:ok, sessions} = SessionsRepository.list_sessions(env)

      # Should only return the valid session
      assert length(sessions) == 1
      assert hd(sessions).id == valid_session.id
    end
  end

  describe "update_session/2" do
    test "overwrites session.json with updated data for active status", %{
      env: env,
      tmp_dir: tmp_dir
    } do
      attrs = %{
        type: AgentTasks.ComponentSpec,
        priority: 1,
        status: :active,
        component_module_name: "MyApp.Component"
      }

      {:ok, session} = SessionsRepository.create_session(env, attrs)

      # Update priority but keep active
      updated_session = %{session | priority: 5}

      assert {:ok, %Session{} = result} = SessionsRepository.update_session(env, updated_session)
      assert result.priority == 5

      # Verify the file remains in the active directory
      session_file = Path.join([tmp_dir, @sessions_dir, session.id, "session.json"])
      json_content = File.read!(session_file)
      {:ok, decoded} = Jason.decode(json_content)
      assert decoded["priority"] == 5
    end

    test "moves session to completed directory when status is :complete", %{
      env: env,
      tmp_dir: tmp_dir
    } do
      {:ok, session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1,
          status: :active
        })

      updated_session = %{session | status: :complete}

      assert {:ok, %Session{} = result} = SessionsRepository.update_session(env, updated_session)
      assert result.status == :complete

      # Verify moved out of active directory
      active_dir = Path.join([tmp_dir, @sessions_dir, session.id])
      refute File.dir?(active_dir)

      # Verify present in completed directory
      completed_file =
        Path.join([tmp_dir, @completed_sessions_dir, session.id, "session.json"])

      assert File.exists?(completed_file)
      {:ok, decoded} = completed_file |> File.read!() |> Jason.decode()
      assert decoded["status"] == "complete"
    end

    test "moves session to completed directory when status is :failed", %{
      env: env,
      tmp_dir: tmp_dir
    } do
      {:ok, session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1
        })

      updated_session = %{session | status: :failed}
      assert {:ok, _} = SessionsRepository.update_session(env, updated_session)

      # Verify moved to completed
      refute File.dir?(Path.join([tmp_dir, @sessions_dir, session.id]))
      assert File.dir?(Path.join([tmp_dir, @completed_sessions_dir, session.id]))
    end

    test "moves session to completed directory when status is :cancelled", %{
      env: env,
      tmp_dir: tmp_dir
    } do
      {:ok, session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1
        })

      updated_session = %{session | status: :cancelled}
      assert {:ok, _} = SessionsRepository.update_session(env, updated_session)

      # Verify moved to completed
      refute File.dir?(Path.join([tmp_dir, @sessions_dir, session.id]))
      assert File.dir?(Path.join([tmp_dir, @completed_sessions_dir, session.id]))
    end

    test "returns error when session directory doesn't exist", %{env: env} do
      non_existent_session = %Session{
        id: Ecto.UUID.generate(),
        type: AgentTasks.ComponentSpec,
        priority: 1,
        status: :active
      }

      assert {:error, _reason} = SessionsRepository.update_session(env, non_existent_session)
    end
  end

  describe "list_completed_sessions/1" do
    test "returns sessions that have been completed", %{env: env} do
      {:ok, session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1
        })

      SessionsRepository.update_session(env, %{session | status: :complete})

      assert {:ok, sessions} = SessionsRepository.list_completed_sessions(env)
      assert length(sessions) == 1
      assert hd(sessions).id == session.id
    end

    test "returns empty list when no completed sessions", %{env: env} do
      SessionsRepository.create_session(env, %{
        type: AgentTasks.ComponentSpec,
        priority: 1
      })

      assert {:ok, []} = SessionsRepository.list_completed_sessions(env)
    end
  end

  describe "delete_session/2" do
    test "removes session directory and all contents", %{env: env, tmp_dir: tmp_dir} do
      attrs = %{
        type: AgentTasks.ComponentSpec,
        priority: 1
      }

      {:ok, session} = SessionsRepository.create_session(env, attrs)

      session_dir = Path.join([tmp_dir, @sessions_dir, session.id])
      assert File.dir?(session_dir)

      assert :ok = SessionsRepository.delete_session(env, session.id)

      refute File.dir?(session_dir)
    end

    test "removes completed session directory", %{env: env, tmp_dir: tmp_dir} do
      {:ok, session} =
        SessionsRepository.create_session(env, %{
          type: AgentTasks.ComponentSpec,
          priority: 1
        })

      # Complete it (moves to completed dir)
      SessionsRepository.update_session(env, %{session | status: :complete})

      completed_dir = Path.join([tmp_dir, @completed_sessions_dir, session.id])
      assert File.dir?(completed_dir)

      assert :ok = SessionsRepository.delete_session(env, session.id)
      refute File.dir?(completed_dir)
    end

    test "returns :ok when directory doesn't exist", %{env: env} do
      non_existent_id = Ecto.UUID.generate()

      assert :ok = SessionsRepository.delete_session(env, non_existent_id)
    end
  end

  describe "clear_sessions/1" do
    test "removes all active and completed session directories", %{env: env, tmp_dir: tmp_dir} do
      # Create sessions
      {:ok, _session1} =
        SessionsRepository.create_session(env, %{type: AgentTasks.ComponentSpec, priority: 1})

      {:ok, session2} =
        SessionsRepository.create_session(env, %{type: AgentTasks.ComponentTest, priority: 2})

      {:ok, _session3} =
        SessionsRepository.create_session(env, %{type: AgentTasks.ComponentCode, priority: 3})

      # Complete one session (moves to completed dir)
      SessionsRepository.update_session(env, %{session2 | status: :complete})

      assert :ok = SessionsRepository.clear_sessions(env)

      # Verify active sessions are gone
      sessions_dir = Path.join(tmp_dir, @sessions_dir)
      {:ok, entries_after} = File.ls(sessions_dir)
      # Only "completed" dir may remain (empty)
      assert entries_after -- ["completed"] == []

      # Verify completed sessions are gone
      assert {:ok, []} = SessionsRepository.list_completed_sessions(env)
    end

    test "returns :ok when sessions directory is empty", %{env: env, tmp_dir: tmp_dir} do
      # Create empty sessions directory
      sessions_dir = Path.join(tmp_dir, @sessions_dir)
      File.mkdir_p!(sessions_dir)

      assert :ok = SessionsRepository.clear_sessions(env)
    end

    test "returns :ok when sessions directory is missing", %{env: env} do
      assert :ok = SessionsRepository.clear_sessions(env)
    end
  end

  # Helper to extract validation errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
