defmodule CodeMySpecSpex.Story1066.Criterion3389Spex do
  @moduledoc """
  Story 1066 — A tool call that is wrong fails like a failure
  Criterion 3389 — The failure names the call.

  The rule:

  > When a call fails, the failure says which tool was called and what was wrong
  > with it.

  ## Mostly true already, and worth pinning anyway

  Today's rejection does name the tool, the argument and the expected type:

      invalid arguments: story_id expected type of :integer received "966" value

  That is good, and it is the part of this story that is not broken. It is
  specified here because the fix for the rest of the story changes how failures
  are produced, and a change that made them louder while making them vaguer
  would trade one problem for a worse one. A raise carrying only "bad argument"
  would satisfy criterion 3390 and leave an agent worse off than it is now.

  A script may make several calls, so naming *which* tool is not decoration —
  it is the difference between fixing the call and reading the whole script.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The failure names the call" do
    scenario "a call failed because an argument was the wrong type" do
      given_ "a script whose call passes the wrong type for a named argument", context do
        {:ok, Map.put(context, :script, ~s|return list_rules({ story_id = "966" })|)}
      end

      when_ "the agent reads why", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = RunScript.execute(%{script: context.script}, frame)

        {:ok, Map.put(context, :text, response_text(response))}
      end

      then_ "it learns which tool was called", context do
        assert context.text =~ "list_rules",
               "the failure does not name the tool. A script that makes six calls fails " <>
                 "somewhere, and an agent that is not told where reads all six. Got:\n" <>
                 String.slice(context.text, 0, 300)

        {:ok, context}
      end

      then_ "and which argument was wrong, and what was expected", context do
        assert context.text =~ "story_id",
               "the failure does not name the argument."

        assert context.text =~ ~r/integer/i,
               "the failure does not say what the argument should have been, so an " <>
                 "agent knows only that it was wrong and guesses at the correction — " <>
                 "which is how the same call gets made twice."

        {:ok, context}
      end
    end
  end
end
