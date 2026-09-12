defmodule CodeMySpecSpex.Story1066.Criterion3386Spex do
  @moduledoc """
  Story 1066 — A tool call that is wrong fails like a failure
  Criterion 3386 — Nothing found reads as nothing found.

  The rule:

  > A call that was malformed and a call that found nothing never look the same.

  ## The half that must keep working

  This is the control. Criterion 3387 asserts that a rejected call cannot be
  mistaken for an empty answer; this one asserts the other side — that an empty
  answer is still a perfectly good answer and does not start looking like a
  failure once failures get louder.

  Worth writing because the obvious fix for 3387 is to make everything shout.
  A sandbox that treats "no rules on this story" as an error has moved the
  problem rather than solved it: an agent would learn to ignore the shouting,
  which is where this started.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Nothing found reads as nothing found" do
    scenario "a script calls a tool that legitimately finds nothing" do
      given_ "a story with no rules on it", context do
        story =
          CodeMySpecSpex.Fixtures.authored_story(context.scope, "A story nobody has ruled on")

        {:ok, Map.put(context, :story, story)}
      end

      when_ "a script asks for its rules", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        script = "return list_rules({ story_id = #{context.story.id} })"

        {:reply, response, _frame} = RunScript.execute(%{script: script}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "the agent can tell the call worked", context do
        refute context.response.isError,
               "asking for the rules of a story that has none came back as a failure. " <>
                 "Nothing went wrong — the answer is that there are no rules — and an " <>
                 "agent taught to treat this as an error learns to ignore errors. " <>
                 "Got:\n#{context.text}"

        {:ok, context}
      end

      then_ "and that the answer was empty", context do
        assert context.text =~ ~r/\(0\)|none|empty|no rules/i,
               "the call worked but the answer does not say it found nothing, so an " <>
                 "agent cannot tell an empty list from a truncated one. Got:\n" <>
                 String.slice(context.text, 0, 300)

        {:ok, context}
      end
    end
  end
end
