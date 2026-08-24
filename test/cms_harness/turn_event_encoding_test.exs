defmodule CmsHarness.TurnEventEncodingTest do
  @moduledoc """
  What a watching operator is shown when an agent takes a step.

  The whole of story 1024 is a person reading this. A step that arrives as an
  inspected Elixir map is technically a step arriving, and it is not watching an
  agent work — QA saw

      %{payload: %{error: nil, id: "call_1", input: %{"file_path" => "mix.exs"},
        name: "read", duration_ms: 7, start_event_seq: 1}, ts_ms: 1787598792387}

  where the transcript should have said `read mix.exs`.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.ChannelClient

  describe "a tool call" do
    test "reads as the tool and what it was pointed at" do
      encoded =
        ChannelClient.encode_turn_event(%{
          event: :tool_result,
          payload: %{name: "read", input: %{"file_path" => "mix.exs"}, duration_ms: 7}
        })

      assert encoded["text"] == "read mix.exs"
      assert encoded["kind"] == "tool_result"
    end

    test "names the tool even when nothing in its arguments identifies the call" do
      encoded =
        ChannelClient.encode_turn_event(%{
          event: :tool_result,
          payload: %{name: "list_agents", input: %{}}
        })

      assert encoded["text"] == "list_agents"
    end

    test "reads arguments that arrived as atoms too" do
      encoded =
        ChannelClient.encode_turn_event(%{
          event: :tool_result,
          payload: %{name: "bash", input: %{command: "mix test"}}
        })

      assert encoded["text"] == "bash mix test"
    end
  end

  describe "everything else" do
    test "a message carries its own text" do
      encoded = ChannelClient.encode_turn_event(%{event: :message, text: "done"})

      assert encoded["text"] == "done"
      assert encoded["kind"] == "message"
    end

    test "a delivery carries the ref, which is the whole of what it says" do
      encoded = ChannelClient.encode_turn_event(%{event: :message_delivered, ref: "r-1"})

      assert encoded["ref"] == "r-1"
      assert encoded["kind"] == "message_delivered"
    end

    test "a shape nobody anticipated still travels rather than being dropped" do
      encoded = ChannelClient.encode_turn_event(%{event: :something_new, mystery: 42})

      assert encoded["kind"] == "something_new"
      assert encoded["text"] =~ "mystery"
    end
  end
end
