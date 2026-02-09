defmodule CodeMySpec.Transcripts.TaskIdentifierTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks.TaskMarker
  alias CodeMySpec.Transcripts.TaskIdentifier

  import CodeMySpec.TranscriptFixtures

  describe "identify/1" do
    @describetag :tmp_dir
    test "extracts marker from user entry with string content", %{tmp_dir: tmp_dir} do
      marker = TaskMarker.build("ComponentTest", "MetricFlow.Accounts.User")

      transcript_content =
        to_jsonl_content([
          user_entry_json(%{
            "message" => %{"role" => "user", "content" => marker <> "\n\nWrite tests for this."}
          }),
          assistant_entry_json()
        ])

      path = write_jsonl_file(tmp_dir, "transcript.jsonl", transcript_content)

      assert {:ok, %{type: "ComponentTest", component: "MetricFlow.Accounts.User"}} =
               TaskIdentifier.identify(path)
    end

    test "skips entries without markers and finds marker in later entry", %{tmp_dir: tmp_dir} do
      marker = TaskMarker.build("ContextSpec", "MetricFlow.Sessions")

      transcript_content =
        to_jsonl_content([
          user_entry_json(),
          user_entry_json(%{
            "uuid" => "user-2",
            "message" => %{"role" => "user", "content" => marker <> "\n\nHere is the spec."}
          })
        ])

      path = write_jsonl_file(tmp_dir, "transcript.jsonl", transcript_content)

      assert {:ok, %{type: "ContextSpec", component: "MetricFlow.Sessions"}} =
               TaskIdentifier.identify(path)
    end

    test "returns :none for transcript without markers", %{tmp_dir: tmp_dir} do
      path = create_valid_transcript(tmp_dir)

      assert :none = TaskIdentifier.identify(path)
    end

    test "returns :none for non-existent file" do
      assert :none = TaskIdentifier.identify("/nonexistent/path.jsonl")
    end

    test "returns :none for empty transcript", %{tmp_dir: tmp_dir} do
      path = create_empty_transcript(tmp_dir)

      assert :none = TaskIdentifier.identify(path)
    end

    test "finds marker in first entry when multiple entries have markers", %{tmp_dir: tmp_dir} do
      first_marker = TaskMarker.build("ComponentSpec", "First.Module")
      second_marker = TaskMarker.build("ComponentCode", "Second.Module")

      transcript_content =
        to_jsonl_content([
          user_entry_json(%{
            "message" => %{"role" => "user", "content" => first_marker <> "\n\nFirst prompt."}
          }),
          user_entry_json(%{
            "uuid" => "user-2",
            "message" => %{"role" => "user", "content" => second_marker <> "\n\nSecond prompt."}
          })
        ])

      path = write_jsonl_file(tmp_dir, "transcript.jsonl", transcript_content)

      assert {:ok, %{type: "ComponentSpec", component: "First.Module"}} =
               TaskIdentifier.identify(path)
    end
  end
end
