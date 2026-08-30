defmodule CodeMySpecSpex.Story1032.Criterion3004Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 3004 — A string bomb is refused before it is built

  Neither an infinite loop nor a blocked host call, so neither of the other
  limits sees it — and the library's own default ceiling is 256 MiB, a string
  this process would build and then try to put in a response.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "A string bomb is refused before it is built" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the script builds one enormous string", context do
        {:reply, response, _frame} =
          RunScript.execute(%{script: ~S[return string.rep("x", 100000000)]}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is refused for being too large", context do
        assert context.response.isError
        assert response_text(context.response) =~ "too large"
        {:ok, context}
      end

      then_ "and the answer is small enough to have been carried", context do
        assert byte_size(response_text(context.response)) < 10_000
        {:ok, context}
      end
    end
  end
end
