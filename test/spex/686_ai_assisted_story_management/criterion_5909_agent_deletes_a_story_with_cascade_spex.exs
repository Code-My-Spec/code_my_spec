defmodule CodeMySpecSpex.Story686.Criterion5909Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5909 — Agent deletes a story that has rules and a linked
  issue. Rules are removed with the story; the issue is preserved with
  its `story_id` cleared.

  Surface: `delete_story`, `list_story_titles`, `list_rules`, `get_issue`
  MCP tools, plus `link_persona_to_story`, `add_rule`, `create_issue`
  for setup.

  DRAFT. Depends on:
    - `Stories.delete_story/2` cascading rule/scenario/criterion deletion.
    - `Issues` schema setting `on_delete: :nilify_all` (or equivalent) on
      the `story_id` foreign key so the issue survives.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.ListRules
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpec.McpServers.Stories.Tools.DeleteStory
  alias CodeMySpec.McpServers.Stories.Tools.ListStoryTitles
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Delete cascades to rules and nullifies the issue's story link" do
    scenario "Story and rules are gone, issue persists with story_id cleared" do
      given_ "a story exists with a linked persona, a rule, and a linked issue, plus an unrelated sibling story",
             context do
        scope = context.scope
        frame = %Frame{assigns: %{current_scope: scope}}

        sibling =
          StoryHelpers.create_story(scope,
            title: "Sibling story",
            description: "Survives the delete; anchors list assertions.",
            acceptance_criteria: []
          )

        story =
          StoryHelpers.create_story(scope,
            title: "Doomed story",
            description: "About to be deleted.",
            acceptance_criteria: []
          )

        {:reply, persona_response, _frame} =
          CreatePersona.execute(
            %{
              name: "Cascade Tester",
              slug: "cascade-tester-#{System.unique_integer([:positive])}",
              description: "Persona used to satisfy add_rule's linkage requirement."
            },
            frame
          )

        persona_id = extract_persona_id(persona_response)

        {:reply, _, _frame} =
          LinkPersonaToStory.execute(
            %{story_id: story.id, persona_id: persona_id},
            frame
          )

        {:reply, _, _frame} =
          AddRule.execute(
            %{story_id: story.id, statement: "Drivers must complete onboarding."},
            frame
          )

        {:reply, issue_response, _frame} =
          CreateIssue.execute(
            %{
              title: "Onboarding step is confusing",
              severity: "medium",
              description: "User reported the step copy was unclear.",
              story_id: story.id
            },
            frame
          )

        issue_id = extract_issue_id(issue_response)

        {:ok, Map.merge(context, %{story: story, sibling: sibling, issue_id: issue_id})}
      end

      when_ "the agent deletes the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          DeleteStory.execute(%{story_id: to_string(context.story.id)}, frame)

        refute response.isError,
               "expected delete_story to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :delete_response, response)}
      end

      then_ "list_story_titles still returns the sibling but not the deleted story",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} = ListStoryTitles.execute(%{}, frame)
        body = response_text(list_response)

        assert body =~ context.sibling.title,
               "anchor failed: expected sibling story to still be listed, got: #{inspect(body)}"

        refute body =~ "Doomed story",
               "expected deleted story to be absent from list_story_titles, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "list_rules for the deleted story returns the no-rules message", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListRules.execute(%{story_id: context.story.id}, frame)

        body = response_text(list_response)

        assert body =~ "No rules on this story",
               "anchor failed: expected the no-rules listing message, got: #{inspect(body)}"

        refute body =~ "Drivers must complete onboarding",
               "expected rule to be cascade-deleted, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the issue still exists and its story link is cleared", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        body = response_text(get_response)

        assert body =~ "Onboarding step is confusing",
               "expected issue to survive story deletion, got: #{inspect(body)}"

        refute body =~ "Story:" <> " " <> to_string(context.story.id),
               "expected issue's story link to be cleared, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_persona_id(response) do
    [_, id] = Regex.run(~r/id:\s*`([^`]+)`/, response_text(response))
    id
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
