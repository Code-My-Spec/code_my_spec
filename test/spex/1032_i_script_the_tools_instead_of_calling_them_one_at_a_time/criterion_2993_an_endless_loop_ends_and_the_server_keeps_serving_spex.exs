defmodule CodeMySpecSpex.Story1032.Criterion2993Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2993 — An endless loop ends and the server keeps serving

  Two halves. The loop has to stop on its own, and the thing that stops it
  must not take the server with it — so a second call after the first proves
  the tool is still answering.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "An endless loop ends and the server keeps serving" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the script loops forever", context do
        {:reply, response, _frame} =
          RunScript.execute(%{script: ~S[while true do end]}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it stops on its own and says it exceeded its budget", context do
        assert context.response.isError
        assert response_text(context.response) =~ "instruction budget exceeded"
        {:ok, context}
      end

      then_ "and the next script still runs", context do
        {:reply, response, _frame} =
          RunScript.execute(%{script: ~S[return "still here"]}, context.frame)

        refute response.isError
        assert response_text(response) =~ "still here"
        {:ok, context}
      end
    end
  end
end
