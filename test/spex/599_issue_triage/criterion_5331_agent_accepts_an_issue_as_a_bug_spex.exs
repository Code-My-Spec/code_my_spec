defmodule CodeMySpecSpex.Story599.Criterion5331Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5331 — Agent accepts an issue as a bug.

  When the agent calls accept_issue with category :bug, the issue transitions
  to :accepted with category :bug set. No story_id is required for this path.

  Surface: `accept_issue` MCP tool.

  NOTE: The `category` field does not yet exist on Issue. This spec drives
  the addition of that field. It is expected to fail until the schema is
  updated.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.IssuesFixtures
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Accept assigns a category" do
    scenario "Agent accepts an issue as a bug" do
      given_ "an incoming issue exists at severity :high", context do
        scope = context.scope
        issue = IssuesFixtures.issue_fixture(scope, %{severity: :high, title: "Bug report issue"})
        {:ok, Map.put(context, :issue, issue)}
      end

      when_ "the agent calls accept_issue with category :bug and the issue's id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AcceptIssue.execute(
            %{issue_id: context.issue.id, category: "bug"},
            frame
          )

        {:ok, Map.put(context, :accept_response, response)}
      end

      then_ "the tool response confirms the issue was accepted", context do
        body = response_text(context.accept_response)

        assert body =~ ~r/accepted/i,
               "expected response to confirm acceptance, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the response indicates the category is bug", context do
        body = response_text(context.accept_response)

        assert body =~ ~r/bug/i,
               "expected response to reflect category :bug, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "no story_id is required for the call to succeed", context do
        body = response_text(context.accept_response)

        refute body =~ ~r/error|invalid|required/i,
               "expected no error when accepting as :bug without story_id, got: #{inspect(body)}"

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
