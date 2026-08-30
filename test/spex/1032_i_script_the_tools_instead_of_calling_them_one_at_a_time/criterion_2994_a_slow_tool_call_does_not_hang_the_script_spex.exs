defmodule CodeMySpecSpex.Story1032.Criterion2994Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2994 — A slow tool call does not hang the script

  Nothing lets a spec make a real tool slow, so the clock is lowered instead —
  the mechanism under test is "work past the wall clock is stopped and
  reported", and lowering the clock reaches it from the other side.

  The limits are configurable for the operator's sake anyway: a harness against
  a slow database wants a longer clock than one on a laptop.
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
          Keyword.put(previous, :timeout, 1)
        )

        on_exit(fn -> Application.put_env(:code_my_spec, CodeMySpec.CodeMode, previous) end)

        {:ok, context}
      end

      when_ "the script calls a tool", context do
        {:reply, response, _frame} =
          RunScript.execute(%{script: ~S[return list_story_titles()]}, context.frame)

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
