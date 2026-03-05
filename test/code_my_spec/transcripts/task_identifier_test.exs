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

    @tag :capture_log
    test "returns :none for non-existent file" do
      assert :none = TaskIdentifier.identify("/nonexistent/path.jsonl")
    end

    test "returns :none for empty transcript", %{tmp_dir: tmp_dir} do
      path = create_empty_transcript(tmp_dir)

      assert :none = TaskIdentifier.identify(path)
    end

    test "finds marker in tool_result with string content", %{tmp_dir: tmp_dir} do
      marker = TaskMarker.build("ComponentTest", "MetricFlow.Accounts.User")

      transcript_content =
        to_jsonl_content([
          user_entry_json(%{
            "message" => %{
              "role" => "user",
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "tool_1",
                  "content" => marker <> "\n\nWrite tests for this component."
                }
              ]
            }
          }),
          assistant_entry_json()
        ])

      path = write_jsonl_file(tmp_dir, "transcript.jsonl", transcript_content)

      assert {:ok, %{type: "ComponentTest", component: "MetricFlow.Accounts.User"}} =
               TaskIdentifier.identify(path)
    end

    test "finds marker in tool_result with nested text blocks", %{tmp_dir: tmp_dir} do
      marker = TaskMarker.build("ComponentSpec", "MetricFlow.Sessions")

      transcript_content =
        to_jsonl_content([
          user_entry_json(%{
            "message" => %{
              "role" => "user",
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "tool_1",
                  "content" => [
                    %{"type" => "text", "text" => marker <> "\n\nSpec content here."}
                  ]
                }
              ]
            }
          }),
          assistant_entry_json()
        ])

      path = write_jsonl_file(tmp_dir, "transcript.jsonl", transcript_content)

      assert {:ok, %{type: "ComponentSpec", component: "MetricFlow.Sessions"}} =
               TaskIdentifier.identify(path)
    end

    test "finds marker only present in tool_result, not in any text block", %{tmp_dir: tmp_dir} do
      marker = TaskMarker.build("ComponentTest", "MetricFlow.Metrics.Counter")

      transcript_content =
        to_jsonl_content([
          # Initial user prompt has no marker
          user_entry_json(%{
            "message" => %{"role" => "user", "content" => "Write tests for this component."}
          }),
          # Assistant reads the prompt file
          assistant_with_tool_use_json(%{
            "uuid" => "assistant-1",
            "message" => %{
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Let me read the prompt file."},
                %{
                  "type" => "tool_use",
                  "id" => "tool_read",
                  "name" => "Read",
                  "input" => %{"file_path" => "/tmp/prompt.md"}
                }
              ]
            }
          }),
          # Tool result contains the marker from the file
          user_with_tool_result_json(%{
            "uuid" => "tool-result-1",
            "parentUuid" => "assistant-1",
            "message" => %{
              "role" => "user",
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "tool_read",
                  "content" => marker <> "\n\n# Component Test Prompt\nWrite tests."
                }
              ]
            }
          })
        ])

      path = write_jsonl_file(tmp_dir, "transcript.jsonl", transcript_content)

      assert {:ok, %{type: "ComponentTest", component: "MetricFlow.Metrics.Counter"}} =
               TaskIdentifier.identify(path)
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
