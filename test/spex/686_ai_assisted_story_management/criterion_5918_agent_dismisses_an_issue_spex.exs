defmodule CodeMySpecSpex.Story686.Criterion5918Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5918 — Agent dismisses an incoming issue with a reason. The
  issue closes as dismissed with the reason attached, and no story is
  modified.

  Surface: `create_issue`, `dismiss_issue`, `get_issue`,
  `list_story_titles` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.DismissIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Stories.Tools.ListStoryTitles
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dismiss an issue with a reason" do
    scenario "Issue closes as dismissed and no story is modified" do
      given_ "an incoming issue exists and an unrelated story exists", context do
        scope = context.scope
        frame = %Frame{assigns: %{current_scope: scope}}

        story =
          StoryHelpers.create_story(scope,
            title: "Untouched story",
            description: "Should not be modified by the dismissal.",
            acceptance_criteria: []
          )

        {:reply, response, _frame} =
          CreateIssue.execute(
            %{
              title: "Cosmetic typo in welcome screen",
              severity: "low",
              description: "Trivial duplicate of an earlier report."
            },
            frame
          )

        issue_id = extract_issue_id(response)

        {:ok, Map.merge(context, %{story: story, issue_id: issue_id})}
      end

      when_ "the agent dismisses the issue with a reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          issue_id: context.issue_id,
          reason: "Duplicate of the earlier welcome-screen report."
        }

        {:reply, response, _frame} = DismissIssue.execute(params, frame)

        refute response.isError,
               "expected dismiss_issue to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :dismiss_response, response)}
      end

      then_ "the response confirms dismissal", context do
        body = response_text(context.dismiss_response)

        assert body =~ ~r/dismissed/i,
               "expected dismissal confirmation, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue reflects the dismissed status and reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        body = response_text(response)

        assert body =~ ~r/dismissed/i,
               "expected issue status dismissed, got: #{inspect(body)}"

        assert body =~ "Duplicate of the earlier welcome-screen report",
               "expected dismissal reason recorded, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the unrelated story is unchanged", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} = ListStoryTitles.execute(%{}, frame)
        body = response_text(list_response)

        assert body =~ context.story.title,
               "expected unrelated story to still exist, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
