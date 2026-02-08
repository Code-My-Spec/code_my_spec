defmodule CodeMySpec.TranscriptsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Transcripts

  # The Transcripts module is a thin facade that delegates to:
  # - Parser.parse/1
  # - FileExtractor.extract_edited_files/1
  # - FileExtractor.get_tool_calls/1
  # - FileExtractor.get_tool_calls/2
  #
  # Those modules have their own comprehensive tests.
  # This test verifies the delegates are wired up correctly.

  describe "parse/1" do
    test "delegates to Parser and returns error for missing file" do
      assert {:error, :file_not_found} = Transcripts.parse("/nonexistent/file.jsonl")
    end
  end

  describe "extract_edited_files/1" do
    test "delegates to FileExtractor" do
      transcript = CodeMySpec.TranscriptFixtures.transcript_with_single_edit()
      assert ["/src/main.ex"] = Transcripts.extract_edited_files(transcript)
    end
  end

  describe "get_tool_calls/1" do
    test "delegates to FileExtractor" do
      transcript = CodeMySpec.TranscriptFixtures.transcript_with_single_edit()
      tool_calls = Transcripts.get_tool_calls(transcript)
      assert length(tool_calls) == 1
      assert hd(tool_calls).name == "Edit"
    end
  end

  describe "get_tool_calls/2" do
    test "delegates to FileExtractor with tool name filter" do
      transcript = CodeMySpec.TranscriptFixtures.transcript_with_edit_and_write()
      edit_calls = Transcripts.get_tool_calls(transcript, "Edit")
      write_calls = Transcripts.get_tool_calls(transcript, "Write")

      assert length(edit_calls) == 1
      assert length(write_calls) == 1
    end
  end
end
