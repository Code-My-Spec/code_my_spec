defmodule CodeMySpecSpex.Story1032.Criterion2996Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2996 — The agent can see what the script was thinking

  `print` writes to real stdout by default, which on a server means the
  script's own debugging lands in the server log where its author never sees
  it.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "The agent can see what the script was thinking" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the script prints as it goes and returns a count", context do
        script = ~S"""
        print("looking at the first")
        print("looking at the second")
        return 2
        """

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the agent gets the count", context do
        refute context.response.isError
        assert response_text(context.response) =~ "2"
        {:ok, context}
      end

      then_ "and the printed lines, in order", context do
        text = response_text(context.response)

        assert text =~ "looking at the first"
        assert text =~ "looking at the second"

        [_before, after_first] = String.split(text, "looking at the first", parts: 2)
        assert after_first =~ "looking at the second"
        {:ok, context}
      end
    end
  end
end
