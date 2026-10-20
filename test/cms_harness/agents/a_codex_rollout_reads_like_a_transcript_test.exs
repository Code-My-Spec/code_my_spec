defmodule CmsHarness.Agents.ACodexRolloutReadsLikeATranscriptTest do
  @moduledoc """
  Story 1129: a Codex session's rollout is read as the same turn events a
  Claude Code transcript is, so one reader serves either.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Transcript

  @moduletag :tmp_dir

  defp rollout(dir, entries) do
    path = Path.join(dir, "rollout.jsonl")
    File.write!(path, Enum.map_join(entries, "", &(Jason.encode!(&1) <> "\n")))
    path
  end

  defp entries do
    [
      %{"type" => "session_meta", "payload" => %{"id" => "01a"}},
      %{"type" => "turn_context", "payload" => %{"model" => "gpt-5-codex"}},
      %{
        "type" => "response_item",
        "payload" => %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Running the specs."}]
        }
      },
      %{
        "type" => "response_item",
        "payload" => %{
          "type" => "function_call",
          "name" => "shell",
          "call_id" => "call_1",
          "arguments" => ~s({"command":["mix","test"]})
        }
      },
      %{
        "type" => "response_item",
        "payload" => %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}
      },
      %{"type" => "event_msg", "payload" => %{"type" => "token_count", "info" => nil}},
      %{
        "type" => "event_msg",
        "payload" => %{
          "type" => "token_count",
          "info" => %{
            "total_token_usage" => %{"total_tokens" => 1540},
            "last_token_usage" => %{
              "input_tokens" => 1200,
              "cached_input_tokens" => 100,
              "output_tokens" => 340
            }
          }
        }
      }
    ]
  end

  test "what it said, the tools it used and what they returned come out as events", %{
    tmp_dir: dir
  } do
    read = Transcript.read(rollout(dir, entries()), 0)

    assert [
             %{event: :message, text: "Running the specs."},
             %{
               event: :tool_start,
               payload: %{id: "call_1", name: "shell", input: %{"command" => ["mix", "test"]}}
             },
             %{event: :tool_end, payload: %{id: "call_1", name: "shell", result: "ok"}}
           ] = read.events
  end

  test "a response's tokens are counted once, under the turn's model", %{tmp_dir: dir} do
    path = rollout(dir, entries() ++ [List.last(entries())])
    read = Transcript.read(path, 0)

    assert [
             %{
               "input_tokens" => 1200,
               "output_tokens" => 340,
               "cache_read_input_tokens" => 100,
               "model" => "gpt-5-codex"
             }
           ] = read.usage
  end

  test "reading on from an offset takes only what is new", %{tmp_dir: dir} do
    path = rollout(dir, Enum.take(entries(), 3))
    first = Transcript.read(path, 0)
    assert [%{event: :message}] = first.events

    File.write!(path, Jason.encode!(Enum.at(entries(), 3)) <> "\n", [:append])
    second = Transcript.read(path, first.offset, first.seen, first.tools)
    assert [%{event: :tool_start, payload: %{name: "shell"}}] = second.events
  end
end
