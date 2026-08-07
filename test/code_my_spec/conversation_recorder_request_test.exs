defmodule CodeMySpec.AgentHarness.ConversationRecorderRequestTest do
  @moduledoc """
  What gets recorded as "what this agent was asked".

  Recorded turns opened with "Available agent types for the Agent tool: …" —
  Claude Code's injected preamble rather than the instruction. An operator
  scanning for what an agent was told to do found boilerplate.

  The last message is the right choice for a simple turn and the wrong one when
  the client appends context to it. Both arrive in the same message, so the fix
  removes the appended part rather than choosing a different message.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentHarness.ConversationRecorder

  defp request(blocks), do: %{"messages" => [%{"role" => "user", "content" => blocks}]}

  describe "a turn carrying injected context alongside the instruction" do
    test "records the instruction, not the preamble" do
      text =
        ConversationRecorder.request_text(
          request([
            %{"type" => "text", "text" => "Fix the failing backups spex."},
            %{
              "type" => "text",
              "text" => "<system-reminder>Available agent types for the Agent tool: …</system-reminder>"
            }
          ])
        )

      assert text == "Fix the failing backups spex."
    end

    test "strips an injected block that arrives first" do
      text =
        ConversationRecorder.request_text(
          request([
            %{"type" => "text", "text" => "<system-reminder>Available agent types…</system-reminder>"},
            %{"type" => "text", "text" => "Record story 969."}
          ])
        )

      assert text == "Record story 969."
    end
  end

  describe "a turn that is nothing but injected context" do
    # Blank would be worse. The turn happened, and an empty request reads as
    # nothing having run — the same failure 8173 names for tool-only turns.
    test "keeps the original rather than recording nothing" do
      text =
        ConversationRecorder.request_text(
          request([
            %{"type" => "text", "text" => "<system-reminder>only context</system-reminder>"}
          ])
        )

      assert text =~ "system-reminder"
    end
  end

  describe "an ordinary turn" do
    test "is unchanged" do
      assert ConversationRecorder.request_text(
               request([%{"type" => "text", "text" => "Just do the thing."}])
             ) == "Just do the thing."
    end

    test "works when content is a plain string" do
      assert ConversationRecorder.request_text(%{
               "messages" => [%{"role" => "user", "content" => "Plain string turn."}]
             }) == "Plain string turn."
    end
  end
end
