defmodule CodeMySpecSpex.Story1033.Criterion3001Spex do
  @moduledoc """
  Story 1033 — I connect with a short tool list
  Criterion 3001 — A tool dropped from the list is still reachable

  The half of the story that keeps it honest. Shortening the list must move
  the tools, not remove them — unregistered is unreachable, not merely
  unadvertised.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript
  alias CodeMySpec.McpServers.{LocalServer, ScriptableTools}
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I connect with a short tool list" do
    scenario "A tool dropped from the list is still reachable" do
      given_ "list_story_titles is no longer in the agent's tool list", context do
        refute "list_story_titles" in MapSet.new(LocalServer.__components__(), & &1.name)

        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      given_ "the project has a story", context do
        {:reply, response, _frame} =
          CreateStory.execute(
            %{title: "Still reachable", story: "As an agent, I want to reach it."},
            context.frame
          )

        refute response.isError

        {:ok, context}
      end

      when_ "the agent runs a script that calls it", context do
        {:reply, response, _frame} =
          RunScript.execute(%{script: ~S[return list_story_titles()]}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it returns what a direct call returned before", context do
        refute context.response.isError

        text =
          context.response
          |> Response.to_protocol()
          |> Map.get("content")
          |> hd()
          |> Map.get("text")

        assert text =~ "Still reachable"
        {:ok, context}
      end
    end
  end
end
