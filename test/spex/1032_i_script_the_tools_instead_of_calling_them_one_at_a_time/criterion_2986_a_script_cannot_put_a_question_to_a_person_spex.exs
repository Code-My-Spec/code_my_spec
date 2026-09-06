defmodule CodeMySpecSpex.Story1032.Criterion2986Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2986 — A script cannot put a question to a person

  A tool that waits on a human means something different inside a loop than a
  read does. `ask_user_question` is not bound into a script at all, so the call fails
  and nobody is asked anything.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "A script cannot put a question to a person" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the script calls ask_user_question", context do
        {:reply, response, _frame} =
          RunScript.execute(
            %{script: ~S[return ask_user_question({ question = "should I?" })]},
            context.frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the script fails", context do
        assert context.response.isError
        {:ok, context}
      end

      then_ "and the failure names the call it could not make", context do
        assert response_text(context.response) =~ "ask_user"
        {:ok, context}
      end
    end
  end
end
