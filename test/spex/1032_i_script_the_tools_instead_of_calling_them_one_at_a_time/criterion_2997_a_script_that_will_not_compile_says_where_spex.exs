defmodule CodeMySpecSpex.Story1032.Criterion2997Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2997 — A script that will not compile says where

  A compile failure has to be distinguishable from a tool that refused, or an
  agent rewrites the wrong thing.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "A script that will not compile says where" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the agent sends a script with a syntax error", context do
        script = "local a = 1\nlocal b = 2\nthis is not lua\n"

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is told the script would not compile", context do
        assert context.response.isError
        assert response_text(context.response) =~ "compile"
        {:ok, context}
      end

      then_ "and no tool was called", context do
        {:reply, listed, _frame} =
          RunScript.execute(%{script: ~S[return list_story_titles()]}, context.frame)

        refute listed.isError
        {:ok, context}
      end
    end
  end
end
