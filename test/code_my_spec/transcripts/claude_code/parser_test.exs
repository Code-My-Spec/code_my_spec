defmodule CodeMySpec.Transcripts.ClaudeCode.ParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Transcripts.ClaudeCode.Entry
  alias CodeMySpec.Transcripts.ClaudeCode.Parser
  alias CodeMySpec.Transcripts.ClaudeCode.Transcript

  import CodeMySpec.TranscriptFixtures

  # ============================================================================
  # parse/1
  # ============================================================================

  describe "parse/1" do
    @describetag :tmp_dir

    test "returns error tuple with :file_not_found for non-existent file path" do
      result = Parser.parse("/nonexistent/path/to/transcript.jsonl")

      assert {:error, :file_not_found} = result
    end

    test "returns error tuple with :json_parse_error for malformed JSON line", %{tmp_dir: tmp_dir} do
      path = create_malformed_transcript(tmp_dir)

      result = Parser.parse(path)

      assert {:error, {:json_parse_error, _line_num, _reason}} = result
    end

    test "includes line number in error for malformed JSON", %{tmp_dir: tmp_dir} do
      path = create_malformed_transcript(tmp_dir)

      {:error, {:json_parse_error, line_num, _reason}} = Parser.parse(path)

      assert line_num == 2
    end

    test "parses valid JSONL transcript into Transcript struct", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)

      result = Parser.parse(path)

      assert {:ok, %Transcript{}} = result
    end

    test "handles empty transcript file returning Transcript with empty entries list", %{tmp_dir: tmp_dir} do
      path = create_empty_transcript(tmp_dir)

      {:ok, transcript} = Parser.parse(path)

      assert %Transcript{} = transcript
      assert transcript.entries == []
    end

    test "preserves entry order matching line order in file", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)

      {:ok, transcript} = Parser.parse(path)

      [first, second] = transcript.entries
      assert first.type == "user"
      assert second.type == "assistant"
    end

    test "handles transcript with single entry", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "single.jsonl", single_entry_jsonl())

      {:ok, transcript} = Parser.parse(path)

      assert length(transcript.entries) == 1
      assert hd(transcript.entries).type == "user"
    end

    test "handles transcript with multiple entries", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "multi.jsonl", tool_use_conversation_jsonl())

      {:ok, transcript} = Parser.parse(path)

      assert length(transcript.entries) == 3
    end

    test "ignores empty lines between entries", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "empty_lines.jsonl", jsonl_with_empty_lines())

      {:ok, transcript} = Parser.parse(path)

      assert length(transcript.entries) == 2
    end

    test "handles trailing newline in file", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "trailing.jsonl", jsonl_with_trailing_newline())

      {:ok, transcript} = Parser.parse(path)

      assert length(transcript.entries) == 2
    end

    test "handles entries with nested JSON structures", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "nested.jsonl", jsonl_with_nested_structures())

      {:ok, transcript} = Parser.parse(path)

      [entry] = transcript.entries
      assert entry.message["metadata"]["nested"]["deeply"]["value"] == [1, 2, 3]
    end

    test "parses entry with type field", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)

      {:ok, transcript} = Parser.parse(path)

      assert Enum.all?(transcript.entries, fn e -> e.type in ["user", "assistant"] end)
    end

    test "parses entry with role field", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)

      {:ok, transcript} = Parser.parse(path)

      assert Enum.all?(transcript.entries, fn e -> Entry.role(e) in ["user", "assistant"] end)
    end

    test "parses entry with content field", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)

      {:ok, transcript} = Parser.parse(path)

      assert Enum.all?(transcript.entries, fn e -> Entry.content(e) != nil end)
    end

    test "handles entries with tool_use content blocks", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "tool_use.jsonl", tool_use_conversation_jsonl())

      {:ok, transcript} = Parser.parse(path)

      assistant_entry = Enum.find(transcript.entries, fn e -> e.type == "assistant" end)
      tool_blocks = Entry.tool_use_blocks(assistant_entry)

      assert length(tool_blocks) == 1
      assert hd(tool_blocks)["name"] == "Read"
    end

    test "handles entries with text content blocks", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "text.jsonl", tool_use_conversation_jsonl())

      {:ok, transcript} = Parser.parse(path)

      assistant_entry = Enum.find(transcript.entries, fn e -> e.type == "assistant" end)
      content = Entry.content(assistant_entry)
      text_block = Enum.find(content, fn c -> c["type"] == "text" end)

      assert text_block["text"] == "Let me read that file."
    end

    test "handles entries with tool_result content blocks", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "tool_result.jsonl", tool_use_conversation_jsonl())

      {:ok, transcript} = Parser.parse(path)

      tool_result_entry = Enum.at(transcript.entries, 2)
      result_blocks = Entry.tool_result_blocks(tool_result_entry)

      assert length(result_blocks) == 1
      assert hd(result_blocks)["tool_use_id"] == "tool_1"
    end

    test "works with absolute file paths", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)
      absolute_path = Path.expand(path)

      {:ok, transcript} = Parser.parse(absolute_path)

      assert transcript.path == absolute_path
    end

    test "works with relative file paths", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)
      cwd = File.cwd!()
      relative_path = Path.relative_to(path, cwd)

      {:ok, transcript} = Parser.parse(relative_path)

      assert %Transcript{} = transcript
    end

    test "handles unicode characters in transcript content", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "unicode.jsonl", jsonl_with_unicode())

      {:ok, transcript} = Parser.parse(path)

      [entry] = transcript.entries
      assert Entry.content(entry) == "Hello 你好 مرحبا 🎉 émoji café"
    end

    test "handles very long lines without truncation", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "long.jsonl", jsonl_with_long_line())

      {:ok, transcript} = Parser.parse(path)

      [entry] = transcript.entries
      assert String.length(Entry.content(entry)) == 10_000
    end

    test "handles special characters in JSON strings", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "special.jsonl", jsonl_with_special_chars())

      {:ok, transcript} = Parser.parse(path)

      [entry] = transcript.entries
      content = Entry.content(entry)

      assert content =~ "\""
      assert content =~ "\\"
      assert content =~ "\n"
      assert content =~ "\t"
    end

    test "returns consistent error structure for all error types" do
      # File not found error structure
      {:error, error1} = Parser.parse("/nonexistent/file.jsonl")
      assert error1 == :file_not_found
    end
  end

  # ============================================================================
  # parse_line/2
  # ============================================================================

  describe "parse_line/2" do
    test "parses valid JSON line into Entry struct" do
      line = to_jsonl_line(user_entry_json())

      result = Parser.parse_line(line, 1)

      assert {:ok, %Entry{}} = result
    end

    test "returns error for invalid JSON syntax" do
      invalid_line = "{not valid json"

      result = Parser.parse_line(invalid_line, 1)

      assert {:error, {:json_parse_error, 1, _reason}} = result
    end

    test "includes line number in error response" do
      invalid_line = "{broken"

      {:error, {:json_parse_error, line_num, _reason}} = Parser.parse_line(invalid_line, 42)

      assert line_num == 42
    end

    test "extracts type field from JSON" do
      line = to_jsonl_line(user_entry_json())

      {:ok, entry} = Parser.parse_line(line, 1)

      assert entry.type == "user"
    end

    test "extracts role field from JSON" do
      line = to_jsonl_line(user_entry_json())

      {:ok, entry} = Parser.parse_line(line, 1)

      assert Entry.role(entry) == "user"
    end

    test "extracts content field from JSON" do
      line = to_jsonl_line(user_entry_json())

      {:ok, entry} = Parser.parse_line(line, 1)

      assert Entry.content(entry) == "Hello, can you help me with this code?"
    end

    test "handles missing optional fields" do
      minimal_json = %{
        "type" => "user",
        "uuid" => "test-uuid",
        "timestamp" => "2024-01-15T10:30:00Z",
        "sessionId" => "session-123",
        "message" => %{"role" => "user", "content" => "test"}
      }

      line = to_jsonl_line(minimal_json)

      {:ok, entry} = Parser.parse_line(line, 1)

      assert entry.parent_uuid == nil
      assert entry.agent_id == nil
      assert entry.cwd == nil
    end

    test "handles null values in JSON" do
      json_with_nulls =
        user_entry_json(%{
          "parentUuid" => nil,
          "agentId" => nil,
          "gitBranch" => nil
        })

      line = to_jsonl_line(json_with_nulls)

      {:ok, entry} = Parser.parse_line(line, 1)

      assert entry.parent_uuid == nil
      assert entry.agent_id == nil
      assert entry.git_branch == nil
    end

    test "handles nested content structures" do
      json_with_nested = assistant_with_tool_use_json()
      line = to_jsonl_line(json_with_nested)

      {:ok, entry} = Parser.parse_line(line, 1)

      content = Entry.content(entry)
      assert is_list(content)
      assert length(content) == 2

      tool_use = Enum.find(content, fn c -> c["type"] == "tool_use" end)
      assert tool_use["input"]["file_path"] == "/src/main.ex"
    end
  end

  # ============================================================================
  # read_lines/1
  # ============================================================================

  describe "read_lines/1" do
    @describetag :tmp_dir

    test "reads file and returns list of non-empty lines", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)

      result = Parser.read_lines(path)

      assert {:ok, lines} = result
      assert is_list(lines)
      assert length(lines) == 2
    end

    test "filters out empty lines", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "empty_lines.jsonl", jsonl_with_empty_lines())

      {:ok, lines} = Parser.read_lines(path)

      assert length(lines) == 2
      assert Enum.all?(lines, fn line -> String.trim(line) != "" end)
    end

    test "filters out whitespace-only lines", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "whitespace.jsonl", jsonl_with_whitespace_lines())

      {:ok, lines} = Parser.read_lines(path)

      assert length(lines) == 2
      assert Enum.all?(lines, fn line -> String.trim(line) != "" end)
    end

    test "returns error for non-existent file" do
      result = Parser.read_lines("/nonexistent/file.jsonl")

      assert {:error, :enoent} = result
    end

    test "returns empty list for empty file", %{tmp_dir: tmp_dir} do
      path = create_empty_transcript(tmp_dir)

      {:ok, lines} = Parser.read_lines(path)

      assert lines == []
    end

    test "handles files with only whitespace", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "whitespace_only.jsonl", "   \n\t\n  \n")

      {:ok, lines} = Parser.read_lines(path)

      assert lines == []
    end

    test "preserves line content without modification", %{tmp_dir: tmp_dir} do
      original_line = to_jsonl_line(user_entry_json())
      path = write_jsonl_file(tmp_dir, "preserve.jsonl", original_line)

      {:ok, [line]} = Parser.read_lines(path)

      assert line == original_line
    end

    test "handles various newline formats (LF, CRLF)", %{tmp_dir: tmp_dir} do
      path = write_jsonl_file(tmp_dir, "crlf.jsonl", jsonl_with_crlf())

      {:ok, lines} = Parser.read_lines(path)

      assert length(lines) == 2
      # Lines should be trimmed of \r
      assert Enum.all?(lines, fn line -> not String.ends_with?(line, "\r") end)
    end
  end
end
