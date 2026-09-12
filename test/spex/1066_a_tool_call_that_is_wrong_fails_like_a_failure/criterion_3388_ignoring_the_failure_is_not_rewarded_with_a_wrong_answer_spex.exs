defmodule CodeMySpecSpex.Story1066.Criterion3388Spex do
  @moduledoc """
  Story 1066 — A tool call that is wrong fails like a failure
  Criterion 3388 — Ignoring the failure is not rewarded with a wrong answer.

  The rule:

  > An agent that fails to check a call does not get a wrong answer in place of
  > a failure.

  ## Not the same claim as criterion 3390

  3390 is about execution: a rejected call stops the script. This is about the
  *reward*: what an agent gets for not checking. The distinction matters because
  a fix could satisfy 3390 and still fail this — a script that halts but hands
  back something answer-shaped leaves the agent exactly where it was.

  The honest framing of the original mistake is that the tool did report the
  failure, in the documented way. `tool_docs` shows
  `local result, err = add_rule({...})` with a nil check, and the agent wrote
  `local _r = add_rule({...})`, discarding `err`. So the agent was wrong.

  The claim here is that being wrong in that particular way should cost a
  failure and not a plausible answer, because discarding a second return value
  is cheap, silent, and something every agent will do sooner or later.

  ## What the script does

  It makes a malformed call, drops the error exactly as the original mistake
  did, and then returns something that looks like an ordinary successful
  answer. If that arrives unmarked, ignoring the failure was rewarded.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Ignoring the failure is not rewarded with a wrong answer" do
    scenario "a script makes a malformed call and does not check whether it failed" do
      given_ "a script that discards the error the way an agent actually does", context do
        script = """
        local _rules = list_rules({ story_id = "966" })
        return "this story has no rules"
        """

        {:ok, Map.put(context, :script, script)}
      end

      when_ "the script carries on", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = RunScript.execute(%{script: context.script}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "it does not proceed as though the call had succeeded", context do
        assert context.response.isError,
               "the script discarded a rejection, carried on, and handed back a " <>
                 "confident sentence about a story it never actually read. That " <>
                 "sentence is what an agent writes down and acts on. Got:\n#{context.text}"

        refute context.text =~ "this story has no rules",
               "the conclusion the script reached on top of a call that never happened " <>
                 "came back as the answer. On 2026-09-12 the equivalent sentence was " <>
                 "believed, and a rule set was written against a story that already had " <>
                 "nine rules."

        {:ok, context}
      end
    end
  end
end
