defmodule CodeMySpec.AgentHarness.ConversationRecorderClientCallsTest do
  @moduledoc """
  An agent's client calls the model for its own housekeeping, and those calls
  reach the proxy as ordinary `/v1/messages` requests — there is nothing about
  them that says they are not the agent talking.

  Recorded, they bury the conversation. Measured on one real session: 2,595 kB
  of housekeeping around 66 kB of actual turns, the worst of it a classifier
  posting the entire transcript every turn and reading back `<severity>8`.

  Every wrapper below is copied from that session rather than invented, because
  the value of a deny-list is entirely in matching what the clients actually
  emit.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentHarness.ConversationRecorder, as: Recorder

  defp request(text), do: %{"messages" => [%{"role" => "user", "content" => text}]}

  describe "calls the client makes for itself" do
    test "the classifier, which posts the whole transcript" do
      assert Recorder.client_side_call?(
               request(~s|<transcript>\n\n{"user":"This session is being continued from a|)
             )
    end

    test "the suggestion generator" do
      assert Recorder.client_side_call?(
               request("[SUGGESTION MODE: Suggest what the user might naturally type next")
             )
    end

    test "the status classifier" do
      assert Recorder.client_side_call?(
               request("Current state: working (for 1m) Tool calls so far: Bash×342, Read×88")
             )
    end
  end

  describe "the agent's own turns" do
    test "ordinary prose is recorded" do
      refute Recorder.client_side_call?(request("Get the chat working in this session."))
    end

    test "a tool result is recorded" do
      refute Recorder.client_side_call?(request("← result: # Session Tasks (7)"))
    end

    test "content blocks rather than a string are recorded" do
      req = %{
        "messages" => [
          %{"role" => "user", "content" => [%{"type" => "text", "text" => "carry on"}]}
        ]
      }

      refute Recorder.client_side_call?(req)
    end

    test "a turn that quotes a wrapper mid-sentence is still the agent's" do
      refute Recorder.client_side_call?(
               request("The classifier posts a <transcript> block, which is the bug.")
             ),
             "the markers are anchored at the start so discussing them stays recordable"
    end

    test "a request with no messages is not mistaken for one" do
      refute Recorder.client_side_call?(%{})
      refute Recorder.client_side_call?(%{"messages" => []})
    end
  end
end
