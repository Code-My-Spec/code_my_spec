defmodule CodeMySpecSpex.Story1032.Criterion2995Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2995 — Three writes land and the fourth failure is reported

  The no-transaction decision, made visible. Our tools call GitHub, Cloudflare
  and Resend; a database transaction could not roll those back, so a script
  that fails partway has already written and has to say so.

  ## Why this reads differently than it did

  The claim is unchanged and so is the scenario. What changed is where the
  script sees the fourth failure, and it changed on purpose.

  This used to catch the failure in Lua — `local bad, err = create_story({})`
  — and return a sentence about it. Story 1032 ("A tool call that is wrong
  fails like a failure") decided that a call the sandbox rejects stops the
  script instead, because a rejection handed back as `nil, err` is two lines
  from an empty answer and a script that discards the second value carries on
  and reports a conclusion it never read.

  So the fourth call now ends the run, and the failure arrives as the response
  rather than as the script's return value. That makes this criterion's point
  more sharply than before, not less: the script was **stopped in the middle**
  and the first three stories are still there. Nothing rolled back. If a
  transaction were ever wrapped around a script, this is the spec that fails.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "Three writes land and the fourth failure is reported" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the script creates three stories and then one that is invalid", context do
        # No longer caught in Lua: the fourth call is rejected and ends the run.
        # The line after it is here to prove that — if it ever appears in the
        # answer, the script was allowed past a call that never happened.
        script = ~S"""
        for _, title in ipairs({ "First landed", "Second landed", "Third landed" }) do
          create_story({ title = title, story = "As an agent, I want " .. title .. "." })
        end
        create_story({})
        return "the fourth unexpectedly worked"
        """

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the answer names the call that failed", context do
        text = response_text(context.response)

        assert context.response.isError,
               "the fourth call failed and the run did not report it as a failure. Got:\n" <>
                 text

        assert text =~ "create_story",
               "the failure does not name the call that failed, so an agent reading it " <>
                 "has to work out which of the four writes stopped the script. Got:\n" <>
                 text

        refute text =~ "the fourth unexpectedly worked",
               "the script carried on past a rejected call and answered anyway."

        {:ok, context}
      end

      then_ "and the first three are still there", context do
        {:reply, listed, _frame} =
          RunScript.execute(%{script: ~S[return list_story_titles()]}, context.frame)

        text = response_text(listed)

        assert text =~ "First landed"
        assert text =~ "Second landed"
        assert text =~ "Third landed"
        {:ok, context}
      end
    end
  end
end
