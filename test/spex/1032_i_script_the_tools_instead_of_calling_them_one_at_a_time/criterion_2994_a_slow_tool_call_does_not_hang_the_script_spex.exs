defmodule CodeMySpecSpex.Story1032.Criterion2994Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2994 — A slow tool call does not hang the script

  Nothing lets a spec make a real tool slow, so the clock is lowered instead —
  the mechanism under test is "work past the wall clock is stopped and
  reported", and lowering the clock reaches it from the other side. The limits
  are configurable for the operator's sake anyway: a harness against a slow
  database wants a longer clock than one on a laptop.

  The first draft set the clock to 1ms and called a tool. It passed here and
  failed in the analyzer sweep, because a tool call against an empty project
  sometimes finishes inside a millisecond — a race I wrote, not a defect it
  found. The script now does work that cannot finish that fast before it makes
  its call, so the clock always wins. The instruction budget is raised for the
  same scenario so that the wall clock, and not the budget, is what stops it —
  otherwise this would pass for the wrong reason.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "A slow tool call does not hang the script" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "the wall clock is set lower than any real call takes", context do
        previous = Application.get_env(:code_my_spec, CodeMySpec.CodeMode, [])

        Application.put_env(
          :code_my_spec,
          CodeMySpec.CodeMode,
          previous
          |> Keyword.put(:timeout, 1)
          |> Keyword.put(:max_instructions, 1_000_000_000)
        )

        on_exit(fn -> Application.put_env(:code_my_spec, CodeMySpec.CodeMode, previous) end)

        {:ok, context}
      end

      when_ "the script works for longer than the clock allows, then calls a tool", context do
        script = ~S"""
        local n = 0
        for i = 1, 3000000 do n = n + i end
        return list_story_titles()
        """

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the agent is told it timed out", context do
        assert context.response.isError
        assert response_text(context.response) =~ "timeout"
        {:ok, context}
      end

      then_ "rather than being left waiting on a call that will not return", context do
        refute response_text(context.response) =~ "still running"
        {:ok, context}
      end
    end
  end
end
