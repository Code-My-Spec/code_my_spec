defmodule CodeMySpec.AgentTasks.TrackEditsTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.AgentTasks.TrackEdits
  alias CodeMySpec.FileEdits

  # ============================================================================
  # Fixtures - Hook Input
  # ============================================================================

  defp write_tool_input(session_id, file_path, opts \\ []) do
    input = %{
      "hook_event_name" => "PostToolUse",
      "session_id" => session_id,
      "tool_name" => "Write",
      "tool_input" => %{
        "file_path" => file_path,
        "content" => "defmodule Foo do\nend"
      }
    }

    if agent_id = Keyword.get(opts, :agent_id) do
      Map.put(input, "agent_id", agent_id)
    else
      input
    end
  end

  defp edit_tool_input(session_id, file_path, opts \\ []) do
    input = %{
      "hook_event_name" => "PostToolUse",
      "session_id" => session_id,
      "tool_name" => "Edit",
      "tool_input" => %{
        "file_path" => file_path,
        "old_string" => "foo",
        "new_string" => "bar"
      }
    }

    if agent_id = Keyword.get(opts, :agent_id) do
      Map.put(input, "agent_id", agent_id)
    else
      input
    end
  end

  defp read_tool_input(session_id, file_path) do
    %{
      "hook_event_name" => "PostToolUse",
      "session_id" => session_id,
      "tool_name" => "Read",
      "tool_input" => %{
        "file_path" => file_path
      }
    }
  end

  defp bash_tool_input(session_id, command) do
    %{
      "hook_event_name" => "PostToolUse",
      "session_id" => session_id,
      "tool_name" => "Bash",
      "tool_input" => %{
        "command" => command
      }
    }
  end

  defp tool_input_missing_file_path(session_id, tool_name) do
    %{
      "hook_event_name" => "PostToolUse",
      "session_id" => session_id,
      "tool_name" => tool_name,
      "tool_input" => %{
        "content" => "some content"
      }
    }
  end

  defp tool_input_no_session(tool_name, file_path) do
    %{
      "hook_event_name" => "PostToolUse",
      "tool_name" => tool_name,
      "tool_input" => %{
        "file_path" => file_path
      }
    }
  end

  # ============================================================================
  # run/1 - Returns empty map (allows proceed)
  # ============================================================================

  describe "run/1" do
    test "returns empty map for Write tool (allows proceed)" do
      session_id = Ecto.UUID.generate()
      hook_input = write_tool_input(session_id, "/path/to/file.ex")

      result = TrackEdits.run(hook_input)

      assert result == %{}

      # Verify file was tracked
      edited_files = FileEdits.get_edited_files(session_id)
      assert "/path/to/file.ex" in edited_files
    end

    test "returns empty map for Edit tool (allows proceed)" do
      session_id = Ecto.UUID.generate()
      hook_input = edit_tool_input(session_id, "/path/to/edited.ex")

      result = TrackEdits.run(hook_input)

      assert result == %{}

      # Verify file was tracked
      edited_files = FileEdits.get_edited_files(session_id)
      assert "/path/to/edited.ex" in edited_files
    end

    test "returns empty map for non-edit tools (Read, Bash, etc.)" do
      session_id = Ecto.UUID.generate()

      # Test Read tool
      read_result = TrackEdits.run(read_tool_input(session_id, "/path/to/file.ex"))
      assert read_result == %{}

      # Test Bash tool
      bash_result = TrackEdits.run(bash_tool_input(session_id, "ls -la"))
      assert bash_result == %{}

      # Verify no files were tracked for non-edit tools
      edited_files = FileEdits.get_edited_files(session_id)
      assert edited_files == []
    end

    test "extracts file_path from Write tool input" do
      session_id = Ecto.UUID.generate()
      expected_path = "/absolute/path/to/new_file.ex"
      hook_input = write_tool_input(session_id, expected_path)

      TrackEdits.run(hook_input)

      edited_files = FileEdits.get_edited_files(session_id)
      assert expected_path in edited_files
    end

    test "extracts file_path from Edit tool input" do
      session_id = Ecto.UUID.generate()
      expected_path = "/absolute/path/to/existing_file.ex"
      hook_input = edit_tool_input(session_id, expected_path)

      TrackEdits.run(hook_input)

      edited_files = FileEdits.get_edited_files(session_id)
      assert expected_path in edited_files
    end

    test "stores file path in session state" do
      session_id = Ecto.UUID.generate()

      # Track multiple files
      TrackEdits.run(write_tool_input(session_id, "/path/one.ex"))
      TrackEdits.run(edit_tool_input(session_id, "/path/two.ex"))
      TrackEdits.run(write_tool_input(session_id, "/path/three.ex"))

      edited_files = FileEdits.get_edited_files(session_id)
      assert length(edited_files) == 3
      assert "/path/one.ex" in edited_files
      assert "/path/two.ex" in edited_files
      assert "/path/three.ex" in edited_files
    end

    test "handles missing session_id gracefully (no error)" do
      hook_input = tool_input_no_session("Write", "/path/to/file.ex")

      # Should not raise, should return empty map
      result = TrackEdits.run(hook_input)
      assert result == %{}
    end

    test "handles missing file_path in input gracefully" do
      session_id = Ecto.UUID.generate()
      hook_input = tool_input_missing_file_path(session_id, "Write")

      # Should not raise, should return empty map
      result = TrackEdits.run(hook_input)
      assert result == %{}

      # Verify no files were tracked
      edited_files = FileEdits.get_edited_files(session_id)
      assert edited_files == []
    end

    test "does not store duplicate paths for same file edited multiple times" do
      session_id = Ecto.UUID.generate()
      file_path = "/path/to/same_file.ex"

      # Edit the same file multiple times
      TrackEdits.run(write_tool_input(session_id, file_path))
      TrackEdits.run(edit_tool_input(session_id, file_path))
      TrackEdits.run(edit_tool_input(session_id, file_path))
      TrackEdits.run(write_tool_input(session_id, file_path))

      edited_files = FileEdits.get_edited_files(session_id)

      # Should only appear once
      assert Enum.count(edited_files, &(&1 == file_path)) == 1
    end

    test "tracks agent_id when present in hook input" do
      session_id = Ecto.UUID.generate()
      agent_id = "sub-agent-123"
      file_path = "/path/to/agent_file.ex"

      TrackEdits.run(write_tool_input(session_id, file_path, agent_id: agent_id))

      # File appears in session-level query
      assert file_path in FileEdits.get_edited_files(session_id)

      # File appears in agent-level query
      assert file_path in FileEdits.get_edited_files_by_agent(session_id, agent_id)
    end

    test "agent-scoped edits are separate from session-level edits" do
      session_id = Ecto.UUID.generate()
      agent_id = "sub-agent-456"

      # Main session edits a file
      TrackEdits.run(write_tool_input(session_id, "/path/main.ex"))

      # Sub-agent edits a different file
      TrackEdits.run(write_tool_input(session_id, "/path/agent.ex", agent_id: agent_id))

      # Session query returns both
      session_files = FileEdits.get_edited_files(session_id)
      assert "/path/main.ex" in session_files
      assert "/path/agent.ex" in session_files

      # Agent query returns only agent's file
      agent_files = FileEdits.get_edited_files_by_agent(session_id, agent_id)
      assert "/path/agent.ex" in agent_files
      refute "/path/main.ex" in agent_files
    end
  end
end
