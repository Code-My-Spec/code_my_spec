defmodule CodeMySpec.Transcripts.ClaudeCode.FileExtractorTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Transcripts.ClaudeCode.FileExtractor
  alias CodeMySpec.Transcripts.ClaudeCode.ToolCall

  import CodeMySpec.TranscriptFixtures

  # ============================================================================
  # extract_edited_files/1
  # ============================================================================

  describe "extract_edited_files/1" do
    test "returns empty list for transcript with no tool calls" do
      transcript = transcript_with_text_only()

      result = FileExtractor.extract_edited_files(transcript)

      assert result == []
    end

    test "returns empty list for transcript with only non-file-modifying tool calls (e.g., Bash, Read)" do
      transcript = transcript_with_read_only_tools()

      result = FileExtractor.extract_edited_files(transcript)

      assert result == []
    end

    test "extracts file_path from Edit tool calls" do
      transcript = transcript_with_single_edit()

      result = FileExtractor.extract_edited_files(transcript)

      assert result == ["/src/main.ex"]
    end

    test "extracts file_path from Write tool calls" do
      transcript = transcript_with_single_write()

      result = FileExtractor.extract_edited_files(transcript)

      assert result == ["/src/new_file.ex"]
    end

    test "extracts file paths from both Edit and Write tool calls in same transcript" do
      transcript = transcript_with_edit_and_write()

      result = FileExtractor.extract_edited_files(transcript)

      assert "/src/foo.ex" in result
      assert "/src/bar.ex" in result
      assert length(result) == 2
    end

    test "returns unique paths when same file is edited multiple times" do
      transcript = transcript_with_duplicate_edits()

      result = FileExtractor.extract_edited_files(transcript)

      assert result == ["/src/main.ex"]
    end

    test "returns unique paths when same file is written multiple times" do
      transcript = transcript_with_duplicate_writes()

      result = FileExtractor.extract_edited_files(transcript)

      assert result == ["/src/new.ex"]
    end

    test "handles tool calls with missing file_path parameter gracefully" do
      transcript = transcript_with_malformed_tool_call()

      result = FileExtractor.extract_edited_files(transcript)

      assert result == ["/src/main.ex"]
    end

    test "preserves chronological order of first occurrence for each unique file" do
      {transcript, expected_order} = transcript_with_chronological_edits()

      result = FileExtractor.extract_edited_files(transcript)

      assert result == expected_order
    end
  end

  # ============================================================================
  # get_tool_calls/1
  # ============================================================================

  describe "get_tool_calls/1" do
    test "returns empty list for empty transcript" do
      transcript = empty_transcript()

      result = FileExtractor.get_tool_calls(transcript)

      assert result == []
    end

    test "returns empty list for transcript with only user/system messages" do
      transcript = transcript_with_user_only()

      result = FileExtractor.get_tool_calls(transcript)

      assert result == []
    end

    test "extracts single tool call from transcript" do
      transcript = transcript_with_single_edit()

      result = FileExtractor.get_tool_calls(transcript)

      assert length(result) == 1
      assert %ToolCall{} = hd(result)
    end

    test "extracts multiple tool calls from single entry" do
      transcript = transcript_with_multiple_tools_single_entry()

      result = FileExtractor.get_tool_calls(transcript)

      assert length(result) == 4
    end

    test "extracts tool calls across multiple entries" do
      transcript = transcript_with_tools_across_entries()

      result = FileExtractor.get_tool_calls(transcript)

      assert length(result) == 3
    end

    test "preserves chronological order of tool calls" do
      transcript = transcript_with_multiple_tools_single_entry()

      result = FileExtractor.get_tool_calls(transcript)

      names = Enum.map(result, & &1.name)
      assert names == ["Read", "Edit", "Bash", "Write"]
    end

    test "extracts tool name correctly" do
      transcript = transcript_with_single_edit()

      [tool_call] = FileExtractor.get_tool_calls(transcript)

      assert tool_call.name == "Edit"
    end

    test "extracts input parameters map correctly" do
      transcript = transcript_with_single_edit()

      [tool_call] = FileExtractor.get_tool_calls(transcript)

      assert tool_call.input["file_path"] == "/src/main.ex"
      assert tool_call.input["old_string"] == "foo"
      assert tool_call.input["new_string"] == "bar"
    end

    test "extracts tool use id for result correlation" do
      transcript = transcript_with_single_edit()

      [tool_call] = FileExtractor.get_tool_calls(transcript)

      assert tool_call.id == "toolu_edit_123"
    end

    test "handles entries with mixed content types (text and tool_use)" do
      transcript = transcript_with_mixed_content()

      result = FileExtractor.get_tool_calls(transcript)

      assert length(result) == 2
      names = Enum.map(result, & &1.name)
      assert "Read" in names
      assert "Edit" in names
    end
  end

  # ============================================================================
  # get_tool_calls/2
  # ============================================================================

  describe "get_tool_calls/2" do
    test "returns empty list when transcript has no tool calls" do
      transcript = empty_transcript()

      result = FileExtractor.get_tool_calls(transcript, "Edit")

      assert result == []
    end

    test "returns empty list when no tool calls match the specified name" do
      transcript = transcript_with_single_edit()

      result = FileExtractor.get_tool_calls(transcript, "Bash")

      assert result == []
    end

    test "returns matching tool calls for valid tool name" do
      transcript = transcript_with_multiple_tools_single_entry()

      result = FileExtractor.get_tool_calls(transcript, "Edit")

      assert length(result) == 1
      assert hd(result).name == "Edit"
    end

    test "filters to only Edit tool calls when specified" do
      transcript = transcript_with_edit_and_write()

      result = FileExtractor.get_tool_calls(transcript, "Edit")

      assert length(result) == 1
      assert Enum.all?(result, fn tc -> tc.name == "Edit" end)
    end

    test "filters to only Write tool calls when specified" do
      transcript = transcript_with_edit_and_write()

      result = FileExtractor.get_tool_calls(transcript, "Write")

      assert length(result) == 1
      assert Enum.all?(result, fn tc -> tc.name == "Write" end)
    end

    test "filters to only Read tool calls when specified" do
      transcript = transcript_with_multiple_tools_single_entry()

      result = FileExtractor.get_tool_calls(transcript, "Read")

      assert length(result) == 1
      assert Enum.all?(result, fn tc -> tc.name == "Read" end)
    end

    test "filters to only Bash tool calls when specified" do
      transcript = transcript_with_multiple_tools_single_entry()

      result = FileExtractor.get_tool_calls(transcript, "Bash")

      assert length(result) == 1
      assert Enum.all?(result, fn tc -> tc.name == "Bash" end)
    end

    test "matches tool name exactly (case-sensitive)" do
      transcript = transcript_with_single_edit()

      result_lowercase = FileExtractor.get_tool_calls(transcript, "edit")
      result_uppercase = FileExtractor.get_tool_calls(transcript, "EDIT")
      result_correct = FileExtractor.get_tool_calls(transcript, "Edit")

      assert result_lowercase == []
      assert result_uppercase == []
      assert length(result_correct) == 1
    end

    test "preserves chronological order of filtered tool calls" do
      transcript = transcript_with_tools_across_entries()

      all_tools = FileExtractor.get_tool_calls(transcript)
      read_tools = FileExtractor.get_tool_calls(transcript, "Read")
      edit_tools = FileExtractor.get_tool_calls(transcript, "Edit")

      all_names = Enum.map(all_tools, & &1.name)
      assert all_names == ["Read", "Edit", "Bash"]

      assert length(read_tools) == 1
      assert hd(read_tools).id == "read_1"

      assert length(edit_tools) == 1
      assert hd(edit_tools).id == "edit_1"
    end
  end
end
