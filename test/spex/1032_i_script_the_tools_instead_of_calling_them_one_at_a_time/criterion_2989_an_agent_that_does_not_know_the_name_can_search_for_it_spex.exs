defmodule CodeMySpecSpex.Story1032.Criterion2989Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2989 — An agent that does not know the name can search for it

  Knowing what you want to do and not what it is called is the ordinary case
  once the tool list is no longer in front of you.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.ToolDocs

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "An agent that does not know the name can search for it" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the agent searches the documentation for epics", context do
        {:reply, response, _frame} = ToolDocs.execute(%{search: "epic"}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the epic tools come back", context do
        assert response_text(context.response) =~ "epic"
        {:ok, context}
      end

      then_ "with one line each rather than their full arguments", context do
        text = response_text(context.response)

        assert text =~ "Ask for one by name"
        refute text =~ "## Arguments"
        {:ok, context}
      end
    end
  end
end
