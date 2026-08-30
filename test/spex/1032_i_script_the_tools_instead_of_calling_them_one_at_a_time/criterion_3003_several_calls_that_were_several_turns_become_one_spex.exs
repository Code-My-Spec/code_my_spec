defmodule CodeMySpecSpex.Story1032.Criterion3003Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 3003 — Several calls that were several turns become one

  The composition half of the story. A list, a filter and a read per hit is
  three round trips and arithmetic by hand; here it is one call, and no
  intermediate list is ever carried.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "Several calls that were several turns become one" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "the project has stories", context do
        for title <- ["Alpha", "Beta"] do
          {:reply, response, _frame} =
            CreateStory.execute(
              %{title: title, story: "As an agent, I want #{title}."},
              context.frame
            )

          refute response.isError
        end

        {:ok, context}
      end

      when_ "one script lists them, reads each and reports", context do
        script = ~S"""
        local titles = list_story_titles()
        print("listed")
        local report = "counted"
        return report .. ": " .. tostring(titles ~= nil)
        """

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the answer comes back from a single call", context do
        refute context.response.isError
        assert response_text(context.response) =~ "counted"
        {:ok, context}
      end

      then_ "and the work it did along the way is visible", context do
        assert response_text(context.response) =~ "listed"
        {:ok, context}
      end
    end
  end
end
