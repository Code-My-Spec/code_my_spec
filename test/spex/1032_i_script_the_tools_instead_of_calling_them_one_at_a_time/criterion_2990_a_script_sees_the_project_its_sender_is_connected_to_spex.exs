defmodule CodeMySpecSpex.Story1032.Criterion2990Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2990 — A script sees the project its sender is connected to

  Authority comes from the connection, not from anything the script says.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "A script sees the project its sender is connected to" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "the project has a story", context do
        # Made through the tool an agent would use, not a fixture: the point of
        # the criterion is that the script sees what this project really has.
        {:reply, response, _frame} =
          CreateStory.execute(
            %{title: "Mine to see", story: "As an agent, I want to read my own project."},
            context.frame
          )

        refute response.isError

        {:ok, context}
      end

      when_ "the script lists stories", context do
        {:reply, response, _frame} =
          RunScript.execute(%{script: ~S[return list_story_titles()]}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it gets that project's stories", context do
        refute context.response.isError
        assert response_text(context.response) =~ "Mine to see"
        {:ok, context}
      end
    end
  end
end
