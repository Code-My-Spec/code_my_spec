defmodule CodeMySpecSpex.Story599.Criterion5332Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5332 — Agent attempts requirements_change accept without a story_id.

  When accept_issue is called with category :requirements_change and no story_id,
  the call is rejected with a validation error. The issue remains :incoming and
  its category remains unset.

  Surface: `accept_issue` MCP tool.

  NOTE: The `category` field and the story_id requirement for
  :requirements_change do not yet exist. This spec drives that behavior.
  Expected to fail until the schema + tool are updated.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.IssuesFixtures
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Accept assigns a category" do
    scenario "Agent attempts requirements_change accept without a story_id" do
      given_ "an incoming issue exists with no linked story_id", context do
        scope = context.scope
        issue = IssuesFixtures.issue_fixture(scope, %{severity: :high, title: "Requirements gap issue"})
        {:ok, Map.put(context, :issue, issue)}
      end

      when_ "the agent calls accept_issue with category :requirements_change and no story_id",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AcceptIssue.execute(
            %{issue_id: context.issue.id, category: "requirements_change"},
            frame
          )

        {:ok, Map.put(context, :accept_response, response)}
      end

      then_ "the call is rejected with a validation error naming the missing story_id", context do
        body = response_text(context.accept_response)

        assert body =~ ~r/error|invalid|required/i,
               "expected a validation error for missing story_id, got: #{inspect(body)}"

        assert body =~ ~r/story_id|story/i,
               "expected the error to name the missing story_id, got: #{inspect(body)}"

        :ok
      end

      then_ "the issue's status remains :incoming", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetIssue.execute(%{issue_id: context.issue.id}, frame)

        body = response_text(get_response)

        assert body =~ ~r/incoming/i,
               "expected the issue status to remain :incoming, got: #{inspect(body)}"

        :ok
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
