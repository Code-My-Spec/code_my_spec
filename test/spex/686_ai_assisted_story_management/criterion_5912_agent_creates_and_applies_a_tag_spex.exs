defmodule CodeMySpecSpex.Story686.Criterion5912Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5912 — Agent lists existing tags, applies a brand-new tag to
  a story, and observes the tag in both the project taxonomy and on the
  story itself.

  Surface: `list_project_tags`, `tag_stories`, `get_story` MCP tools.

  Tagging implicitly creates the tag on first use, so no separate
  `create_tag` call is required for this scenario.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias CodeMySpec.McpServers.Stories.Tools.ListProjectTags
  alias CodeMySpec.McpServers.Stories.Tools.TagStories
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent applies a new tag and the project taxonomy grows" do
    scenario "New tag appears in list_project_tags and on the story" do
      given_ "a story exists in the active project", context do
        scope = context.scope

        story =
          StoryHelpers.create_story(scope,
            title: "Story to be tagged",
            description: "Receives a brand-new tag.",
            acceptance_criteria: []
          )

        # Unique tag per run so the scenario is independent of any
        # taxonomy state already in the project.
        tag = "epic:onboarding-#{System.unique_integer([:positive])}"

        {:ok, Map.merge(context, %{story: story, tag: tag})}
      end

      when_ "the agent calls tag_stories with a brand-new tag", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          story_ids: [to_string(context.story.id)],
          tag: context.tag
        }

        {:reply, response, _frame} = TagStories.execute(params, frame)

        refute response.isError,
               "expected tag_stories to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :tag_response, response)}
      end

      then_ "list_project_tags now includes the new tag", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} = ListProjectTags.execute(%{}, frame)
        body = response_text(list_response)

        assert body =~ context.tag,
               "expected new tag in project taxonomy, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_story shows the tag on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetStory.execute(%{story_id: to_string(context.story.id)}, frame)

        body = response_text(get_response)

        assert body =~ context.tag,
               "expected tag on story output, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
