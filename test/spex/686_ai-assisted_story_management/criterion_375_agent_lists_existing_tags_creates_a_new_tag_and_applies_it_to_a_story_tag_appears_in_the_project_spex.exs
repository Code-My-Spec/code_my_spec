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

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent applies a new tag and the project taxonomy grows", criterion: 375 do
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
          story_numbers: [context.story.number],
          tag: context.tag
        }

        response =
          ToolLibrary.run(
            "tag_stories",
            params,
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected tag_stories to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :tag_response, response)}
      end

      then_ "list_project_tags now includes the new tag", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        list_response =
          ToolLibrary.run(
            "list_project_tags",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        body = response_text(list_response)

        assert body =~ context.tag,
               "expected new tag in project taxonomy, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_story shows the tag on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        get_response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        body = response_text(get_response)

        assert body =~ context.tag,
               "expected tag on story output, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
