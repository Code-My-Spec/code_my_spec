defmodule CodeMySpecSpex.Story1032.Criterion2988Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2988 — Asking about one tool returns one tool

  The whole reason documentation is looked up rather than carried: asking
  about one tool must not cost what carrying all of them costs.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.ToolDocs

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "Asking about one tool returns one tool" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the agent asks for one tool's documentation", context do
        {:reply, response, _frame} = ToolDocs.execute(%{name: "get_story"}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it gets that tool's arguments", context do
        text = response_text(context.response)

        assert text =~ "get_story"
        assert text =~ "story_id"
        {:ok, context}
      end

      then_ "and not the other hundred", context do
        text = response_text(context.response)

        refute text =~ "create_epic"
        refute text =~ "run_devops_setup"
        {:ok, context}
      end
    end
  end
end
