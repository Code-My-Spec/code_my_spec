defmodule CodeMySpec.Transcripts.ClaudeCode.ToolCallTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Transcripts.ClaudeCode.ToolCall

  import CodeMySpec.TranscriptFixtures

  # ============================================================================
  # Local Fixture Helpers (build on shared fixtures)
  # ============================================================================

  defp edit_tool_call do
    ToolCall.new(edit_tool_json())
  end

  defp write_tool_call do
    ToolCall.new(write_tool_json())
  end

  defp read_tool_call do
    ToolCall.new(read_tool_json())
  end

  defp bash_tool_call do
    ToolCall.new(bash_tool_json())
  end

  defp glob_tool_call do
    ToolCall.new(glob_tool_json())
  end

  # ============================================================================
  # new/1
  # ============================================================================

  describe "new/1" do
    test "creates struct with id, name and input from map" do
      tool_call = ToolCall.new(read_tool_json())

      assert %ToolCall{} = tool_call
      assert tool_call.name == "Read"
      assert tool_call.input == %{"file_path" => "/src/main.ex"}
    end

    test "extracts id field for tool_use correlation" do
      tool_call = ToolCall.new(edit_tool_json(%{"id" => "toolu_abc123"}))

      assert tool_call.id == "toolu_abc123"
    end

    test "defaults result to nil when not provided" do
      tool_call = ToolCall.new(read_tool_json())

      assert tool_call.result == nil
    end

    test "includes result when provided in map" do
      tool_call = ToolCall.new(read_tool_json(%{"result" => "file contents here"}))

      assert tool_call.result == "file contents here"
    end

    test "handles string keys in input map" do
      tool_call = ToolCall.new(read_tool_json())

      assert tool_call.id == "toolu_read_789"
      assert tool_call.name == "Read"
    end

    test "handles atom keys in input map" do
      tool_call =
        ToolCall.new(%{
          id: "toolu_456",
          name: "Write",
          input: %{file_path: "/src/new.ex"}
        })

      assert tool_call.id == "toolu_456"
      assert tool_call.name == "Write"
    end
  end

  # ============================================================================
  # file_path/1
  # ============================================================================

  describe "file_path/1" do
    test "returns file_path for Edit tool call" do
      tool_call = edit_tool_call()

      assert ToolCall.file_path(tool_call) == "/src/main.ex"
    end

    test "returns file_path for Write tool call" do
      tool_call = write_tool_call()

      assert ToolCall.file_path(tool_call) == "/src/new_file.ex"
    end

    test "returns nil for tool calls without file_path" do
      tool_call = bash_tool_call()

      assert ToolCall.file_path(tool_call) == nil
    end

    test "returns nil for empty input map" do
      tool_call =
        ToolCall.new(%{
          "id" => "toolu_empty",
          "name" => "Unknown",
          "input" => %{}
        })

      assert ToolCall.file_path(tool_call) == nil
    end
  end

  # ============================================================================
  # file_modifying?/1
  # ============================================================================

  describe "file_modifying?/1" do
    test "returns true for Edit tool" do
      tool_call = edit_tool_call()

      assert ToolCall.file_modifying?(tool_call) == true
    end

    test "returns true for Write tool" do
      tool_call = write_tool_call()

      assert ToolCall.file_modifying?(tool_call) == true
    end

    test "returns false for Read tool" do
      tool_call = read_tool_call()

      assert ToolCall.file_modifying?(tool_call) == false
    end

    test "returns false for Bash tool" do
      tool_call = bash_tool_call()

      assert ToolCall.file_modifying?(tool_call) == false
    end

    test "returns false for Glob tool" do
      tool_call = glob_tool_call()

      assert ToolCall.file_modifying?(tool_call) == false
    end
  end
end
