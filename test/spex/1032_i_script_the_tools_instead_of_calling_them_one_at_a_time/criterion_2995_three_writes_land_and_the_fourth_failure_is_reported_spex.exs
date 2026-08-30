defmodule CodeMySpecSpex.Story1032.Criterion2995Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2995 — Three writes land and the fourth failure is reported

  The no-transaction decision, made visible. Our tools call GitHub, Cloudflare
  and Resend; a database transaction could not roll those back, so a script
  that fails partway has already written and has to say so.
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
        script = ~S"""
        for _, title in ipairs({ "First landed", "Second landed", "Third landed" }) do
          create_story({ title = title, story = "As an agent, I want " .. title .. "." })
        end
        local bad, err = create_story({})
        if bad == nil then return "failed on the fourth: " .. err.message end
        return "the fourth unexpectedly worked"
        """

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the answer names the call that failed", context do
        assert response_text(context.response) =~ "failed on the fourth"
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
