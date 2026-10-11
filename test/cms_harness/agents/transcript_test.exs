defmodule CmsHarness.Agents.TranscriptTest do
  @moduledoc """
  Every message the loop appends leaves the machine as it is appended: the
  assistant's words with the calls they asked for, then what those calls
  returned. That is the conversation a restart resumes from.

  Driven at the middleware, as `CompactionTest` is: what is under test is what
  gets reported, not Alloy's decision to call the hook.
  """
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Message
  alias CmsHarness.Agents.Transcript

  defp state_after(messages, appended, calls \\ []) do
    parent = self()

    Config.from_opts(context: %{on_transcript: &send(parent, {:reported, &1})})
    |> State.init(messages)
    |> State.append_messages(appended)
    |> State.append_tool_calls(calls)
  end

  test "the assistant message that asked for calls goes up whole, before they run" do
    asked =
      Message.assistant_blocks([
        %{type: "thinking", thinking: "private"},
        %{type: "text", text: "Reading it."},
        %{type: "tool_use", id: "c1", name: "read", input: %{"path" => "mix.exs"}}
      ])

    state = state_after([Message.user("look at mix.exs")], asked)

    assert %State{} = Transcript.call(:after_tool_request, state)
    assert_receive {:reported, %{event: :transcript, message: message}}

    assert message == %{
             "role" => "assistant",
             "content" => [
               %{"type" => "text", "text" => "Reading it."},
               %{
                 "type" => "tool_use",
                 "id" => "c1",
                 "name" => "read",
                 "input" => %{"path" => "mix.exs"}
               }
             ]
           }
  end

  test "results go up whole, named, and marked when they failed" do
    results =
      Message.tool_results([
        Message.tool_result_block("c1", String.duplicate("x", 20_000)),
        Message.tool_result_block("c2", "bash failed: exit 1", true)
      ])

    state = state_after([], results, [%{id: "c1", name: "read"}, %{id: "c2", name: "bash"}])

    Transcript.call(:after_tool_execution, state)
    assert_receive {:reported, %{message: %{"role" => "user", "content" => [read, bash]}}}

    assert {read["name"], byte_size(read["content"]), read["is_error"]} == {"read", 20_000, false}
    assert {bash["name"], bash["is_error"]} == {"bash", true}
  end

  test "other hooks report nothing, and a raising reporter keeps the turn" do
    state = state_after([], Message.assistant("done"))

    assert %State{} = Transcript.call(:after_completion, state)
    refute_receive {:reported, _}

    raising = put_in(state.config.context[:on_transcript], fn _ -> raise "boom" end)
    assert %State{} = Transcript.call(:after_tool_request, raising)
  end
end
