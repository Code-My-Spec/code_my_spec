defmodule CodeMySpecSpex.Story599.Criterion5334Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5334 — Agent attempts dismiss without a resolution.

  When dismiss_issue is called with an empty reason, the call is rejected
  with a validation error on the resolution field. The issue remains :incoming.

  Surface: `dismiss_issue` MCP tool.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.DismissIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dismiss requires a resolution" do
    scenario "Agent attempts dismiss without a resolution" do
      given_ "an incoming issue exists", context do
        scope = context.scope
        issue = Fixtures.issue_fixture(scope, %{severity: :medium, title: "Issue to dismiss"})
        {:ok, Map.put(context, :issue, issue)}
      end

      when_ "the agent calls dismiss_issue with an empty reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          DismissIssue.execute(
            %{issue_id: context.issue.id, reason: ""},
            frame
          )

        {:ok, Map.put(context, :dismiss_response, response)}
      end

      then_ "the call is rejected with a validation error on resolution", context do
        body = response_text(context.dismiss_response)

        assert body =~ ~r/error|invalid|required/i,
               "expected a validation error when dismissing with empty reason, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the issue's status remains :incoming", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetIssue.execute(%{issue_id: context.issue.id}, frame)

        body = response_text(get_response)

        assert body =~ ~r/incoming/i,
               "expected issue status to remain :incoming, got: #{inspect(body)}"

        {:ok, context}
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
