defmodule CmsHarness.Agents.TranscriptTest do
  @moduledoc """
  Story 1124: a terminal session's conversation and usage come from its
  transcript, read as the turn events an agent we run reports.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Transcript

  @moduletag :tmp_dir

  @usage %{
    "input_tokens" => 10,
    "output_tokens" => 5,
    "cache_read_input_tokens" => 100,
    "cache_creation_input_tokens" => 7
  }

  # Claude Code writes one line per content block and repeats the response's
  # id and usage on each.
  defp lines do
    [
      %{"type" => "permission-mode", "permissionMode" => "default"},
      %{
        "type" => "assistant",
        "message" => %{
          "id" => "msg_1",
          "model" => "claude-opus-5-5",
          "usage" => @usage,
          "content" => [%{"type" => "text", "text" => "Reading the spec first."}]
        }
      },
      %{
        "type" => "assistant",
        "message" => %{
          "id" => "msg_1",
          "model" => "claude-opus-5-5",
          "usage" => @usage,
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "tu_1",
              "name" => "Read",
              "input" => %{"file_path" => "a.ex"}
            }
          ]
        }
      },
      %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "tu_1", "content" => "defmodule A"}
          ]
        }
      }
    ]
    |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))
  end

  test "what the session said and did comes back as steps, calls and results", %{tmp_dir: dir} do
    path = Path.join(dir, "s.jsonl")
    File.write!(path, lines())

    read = Transcript.read(path, 0)

    assert [
             %{event: :message, text: "Reading the spec first."},
             %{
               event: :tool_start,
               payload: %{id: "tu_1", name: "Read", input: %{"file_path" => "a.ex"}}
             },
             %{
               event: :tool_end,
               payload: %{id: "tu_1", name: "Read", result: "defmodule A", error: nil}
             }
           ] = read.events

    assert read.offset == byte_size(lines())
  end

  test "a response's usage is counted once, with its model", %{tmp_dir: dir} do
    path = Path.join(dir, "s.jsonl")
    File.write!(path, lines())

    assert [usage] = Transcript.read(path, 0).usage
    assert usage["output_tokens"] == 5
    assert usage["model"] == "claude-opus-5-5"
  end

  test "a half-written line waits, and reading resumes where it left off", %{tmp_dir: dir} do
    path = Path.join(dir, "s.jsonl")
    File.write!(path, lines() <> ~s({"type":"assistant","mess))

    first = Transcript.read(path, 0)
    assert first.offset == byte_size(lines())

    File.write!(path, lines() <> ~s({"type":"user","message":{"content":"hi"}}\n))
    again = Transcript.read(path, first.offset, first.seen, first.tools)

    assert again.events == []
    assert again.usage == []
  end

  test "reading starts from where the transcript ends", %{tmp_dir: dir} do
    path = Path.join(dir, "s.jsonl")
    File.write!(path, lines())

    assert Transcript.end_of(path) == byte_size(lines())
    assert Transcript.end_of(Path.join(dir, "missing.jsonl")) == 0
    assert Transcript.end_of(nil) == 0
  end
end
