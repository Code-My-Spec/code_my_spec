defmodule CodeMySpecSpex.Story958.Criterion7943Spex do
  @moduledoc """
  Story 958 — Mark Stories Ready for Development to Control Pace
  Criterion 7943 — Un-readying a story with work already in flight.

  Parking a story mid-flight stops NEW requirements being offered, but must
  not destroy work already done. "Partway through implementation" is
  represented by the story having a linked surface component — the first
  satisfied step of its chain.

  Surface: StoryLive (LiveView) to park the story, `show_story_requirements`
  and `get_story` MCP tools to observe.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  @title "Players have a discrete age"

  spex "Un-readying a story with work already in flight" do
    scenario "New requirements stop, completed work survives" do
      given_ :synced_context_component

      given_ "the story \"#{@title}\" is ready for development", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateStory.execute(
            %{
              title: @title,
              description:
                "As the game world, I want each player to sit in one age so that age gaps drive politics."
            },
            frame
          )

        refute response.isError, "expected create_story to succeed"

        {:ok, index_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories")

        index_live
        |> element("[data-test='toggle-story-ready']")
        |> render_click()

        {:ok, Map.put(context, :story_id, story_id!(response))}
      end

      and_ "it is partway through implementation", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SetStoryComponent.execute(
            %{story_id: context.story_id, module_name: context.component.module_name},
            frame
          )

        refute response.isError,
               "expected the story to be linked to a component, got: #{inspect(response)}"

        {:ok, context}
      end

      when_ "the user marks it not ready for development", context do
        {:ok, index_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories")

        html =
          index_live
          |> element("[data-test='toggle-story-ready']")
          |> render_click()

        {:ok, Map.put(context, :park_html, html)}
      end

      then_ "the graph stops offering new requirements for that story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ShowStoryRequirements.execute(%{story: @title}, frame)

        body = response_text(response)

        refute body =~ "bdd_specs_exist",
               "expected a parked story to stop producing new requirements, got: #{body}"

        {:ok, context}
      end

      and_ "the work already completed on it is preserved", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetStory.execute(%{story_id: context.story_id}, frame)

        body = response_text(response)

        refute response.isError,
               "expected the parked story to still be readable, got: #{inspect(response)}"

        assert body =~ @title,
               "expected the parked story to survive, got: #{body}"

        assert body =~ context.component.module_name,
               "expected the component link established before parking to be preserved, got: #{body}"

        {:ok, context}
      end
    end
  end

  # MCP responses carry record ids in the text footer.
  defp story_id!(response) do
    body = response_text(response)

    case Regex.run(~r/\(ID: (\d+)\)/, body) do
      [_, id] -> id
      _ -> raise "could not read story id from response: #{body}"
    end
  end
end
