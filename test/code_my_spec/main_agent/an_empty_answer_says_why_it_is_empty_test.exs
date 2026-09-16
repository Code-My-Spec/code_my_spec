defmodule CodeMySpec.MainAgent.AnEmptyAnswerSaysWhyItIsEmptyTest do
  @moduledoc """
  Issue `2a809b93`. A narrowed read that matches nothing and a conversation that
  is genuinely empty both arrive at the mapper as `turns: []`, and they mean
  opposite things — one says there is nothing to read, the other says there is
  plenty and none of it matched.

  Found by QA against live agents rather than by the spex, which pass either
  way: an agent with a long history was reported as having said nothing at all,
  because it had never called the tool asked about. The agent reading that
  decides whether to look elsewhere on the strength of it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.MainAgent.MainAgentMapper

  defp text(response), do: CodeMySpecSpex.TaskResponseHelpers.response_text(response)

  describe "an empty conversation" do
    test "says the agent has not taken a turn" do
      said = text(MainAgentMapper.conversation(%{turns: [], truncated?: false}))

      assert said =~ "said nothing yet"
    end
  end

  describe "an empty answer to a narrowed read" do
    test "names the tool that was never called, and says the conversation is not empty" do
      said =
        text(MainAgentMapper.conversation(%{turns: [], no_match: {:last_call_of, "promote"}}))

      assert said =~ "never called",
             """
             A `last_call_of` miss was reported the same way as an agent that has
             never spoken. Those mean opposite things to the caller deciding
             whether to look elsewhere.

             Said: #{said}
             """

      assert said =~ "promote",
             "the answer should name the tool that was asked about, so the caller can retry without it"

      refute said =~ "said nothing yet",
             "an agent with turns must not be reported as having said nothing"
    end

    test "a window that matches nothing says so rather than claiming silence" do
      said = text(MainAgentMapper.conversation(%{turns: [], no_match: :window}))

      assert said =~ "window"
      refute said =~ "said nothing yet"
    end
  end
end
