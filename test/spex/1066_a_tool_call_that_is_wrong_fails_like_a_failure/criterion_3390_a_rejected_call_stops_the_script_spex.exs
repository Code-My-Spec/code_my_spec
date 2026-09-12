defmodule CodeMySpecSpex.Story1066.Criterion3390Spex do
  @moduledoc """
  Story 1066 — A tool call that is wrong fails like a failure
  Criterion 3390 — A rejected call stops the script.

  The rule:

  > A call the sandbox rejects stops the script rather than answering it.

  ## The failure this is written from

  On 2026-09-12 an agent called `list_rules({ story_id = "966" })` — a string
  where the tool wants an integer. The sandbox rejected it and the script
  carried on, returning the rejection as the script's own value. Rendered, that
  is `[null, {"message": "...expected type of :integer..."}]`, which at a glance
  reads like an empty result. The agent concluded story 966 had no rules and
  wrote a rule set on top of that belief. It had nine.

  ## What is asserted, and how it can fail honestly

  The script below makes a malformed call and then, on the next line, produces
  a value that could only exist if execution continued. If that value comes
  back, the call did not stop the script. The marker is deliberately something
  no tool returns, so a passing assertion cannot be confused with a tool having
  answered.

  Today this fails: the script runs to completion and hands back the marker.
  That is the point of writing it now.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  @marker "EXECUTION-CONTINUED-PAST-A-REJECTED-CALL"

  spex "A rejected call stops the script" do
    scenario "a script calls a tool with an argument of the wrong type" do
      given_ "a script whose first call is malformed and which does more afterwards",
             context do
        script = """
        local _ignored = list_rules({ story_id = "not-an-integer" })
        return "#{@marker}"
        """

        {:ok, Map.put(context, :script, script)}
      end

      when_ "the script runs", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = RunScript.execute(%{script: context.script}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "it stops at that call", context do
        assert context.response.isError,
               "the sandbox rejected a call and the script was allowed to finish anyway, " <>
                 "so the rejection is something the agent has to notice rather than " <>
                 "something that happened to it. Got:\n#{context.text}"

        {:ok, context}
      end

      then_ "and nothing after it is executed", context do
        refute context.text =~ @marker,
               "the line after the rejected call ran. Everything an agent writes after a " <>
                 "call it got wrong is built on a call that never happened — which is " <>
                 "how one wrong argument became a rule set written against a story that " <>
                 "already had nine rules."

        {:ok, context}
      end
    end
  end
end
