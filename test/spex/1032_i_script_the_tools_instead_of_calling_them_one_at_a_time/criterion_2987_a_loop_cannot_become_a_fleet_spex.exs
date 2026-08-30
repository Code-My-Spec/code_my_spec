defmodule CodeMySpecSpex.Story1032.Criterion2987Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2987 — A loop cannot become a fleet

  `start_agent` spawns background work. A loop around it is a fleet nobody
  asked for, so it is not bound into a script and the first call ends it.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "A loop cannot become a fleet" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the script loops start_agent over twenty stories", context do
        script = ~S"""
        for i = 1, 20 do
          start_agent({ agent_type = "code-writer" })
        end
        return "spawned"
        """

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the script fails on the first call", context do
        assert context.response.isError
        {:ok, context}
      end

      then_ "and never reports having spawned anything", context do
        refute response_text(context.response) =~ "spawned"
        {:ok, context}
      end
    end
  end
end
