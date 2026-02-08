defmodule CodeMySpec.Transcripts.ClaudeCode.TranscriptTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Transcripts.ClaudeCode.Entry
  alias CodeMySpec.Transcripts.ClaudeCode.Transcript

  import CodeMySpec.TranscriptFixtures

  # ============================================================================
  # Local Fixture Helpers
  # ============================================================================

  defp sample_path, do: "/path/to/transcript.jsonl"
  defp alternate_path, do: "/another/path/to/session.jsonl"

  defp sample_user_entry do
    Entry.new(user_entry_json())
  end

  defp sample_assistant_entry do
    Entry.new(assistant_entry_json())
  end

  defp sample_entries do
    [sample_user_entry(), sample_assistant_entry()]
  end

  # ============================================================================
  # new/1
  # ============================================================================

  describe "new/1" do
    test "creates struct with path and empty entries by default" do
      transcript = Transcript.new(path: sample_path())

      assert is_struct(transcript, Transcript)
      assert transcript.path == sample_path()
      assert transcript.entries == []
    end

    test "creates struct with provided entries list" do
      entries = sample_entries()
      transcript = Transcript.new(path: sample_path(), entries: entries)

      assert is_struct(transcript, Transcript)
      assert transcript.path == sample_path()
      assert transcript.entries == entries
      assert length(transcript.entries) == 2
    end

    test "raises when path is not provided" do
      assert_raise KeyError, fn ->
        Transcript.new([])
      end
    end
  end

  # ============================================================================
  # new/2
  # ============================================================================

  describe "new/2" do
    test "creates struct with given path and entries" do
      entries = sample_entries()
      transcript = Transcript.new(sample_path(), entries)

      assert is_struct(transcript, Transcript)
      assert transcript.path == sample_path()
      assert transcript.entries == entries
      assert length(transcript.entries) == 2
    end

    test "accepts empty entries list" do
      transcript = Transcript.new(alternate_path(), [])

      assert is_struct(transcript, Transcript)
      assert transcript.path == alternate_path()
      assert transcript.entries == []
    end
  end
end
