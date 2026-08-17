defmodule CodeMySpecSpex.Story686.Criterion5916Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5916 — Agent accepts an incoming issue as a requirements
  change, linking it to a story. The issue closes with category
  `requirements_change` and the link to the target story is recorded.

  Surface: `create_issue`, `accept_issue`, `get_issue` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Accept an issue as a requirements change linked to a story" do
    scenario "Issue closes as requirements_change and links to the target story" do
      given_ "an incoming issue exists and a target story exists", context do
        scope = context.scope
        frame = %Frame{assigns: %{current_scope: scope}}

        story =
          StoryHelpers.create_story(scope,
            title: "Onboarding flow",
            description: "Targeted by an incoming issue.",
            acceptance_criteria: []
          )

        {:reply, issue_response, _frame} =
          CreateIssue.execute(
            %{
              title: "Welcome step omits a confirmation",
              severity: "high",
              description: "Users miss the confirmation message after sign-up."
            },
            frame
          )

        issue_id = extract_issue_id(issue_response)

        {:ok, Map.merge(context, %{story: story, issue_id: issue_id})}
      end

      when_ "the agent accepts the issue with category requirements_change linked to the story",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          issue_id: context.issue_id,
          story_id: context.story.id,
          category: "requirements_change"
        }

        {:reply, response, _frame} = AcceptIssue.execute(params, frame)

        refute response.isError,
               "expected accept_issue to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :accept_response, response)}
      end

      then_ "the response confirms acceptance with the requirements_change disposition",
            context do
        body = response_text(context.accept_response)

        assert body =~ ~r/accepted/i,
               "expected acceptance confirmation, got: #{inspect(body)}"

        assert body =~ ~r/requirements_change/i,
               "expected requirements_change category in response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue reflects the link to the target story and the new status",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        body = response_text(get_response)

        assert body =~ ~r/accepted/i,
               "expected issue status accepted, got: #{inspect(body)}"

        assert body =~ to_string(context.story.id),
               "expected issue linked to story #{context.story.id}, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
