defmodule CodeMySpecSpex.Story599.Criterion5333Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5333 — Agent dismisses a duplicate with a reason naming the canonical issue.

  When two issues describe the same problem, the agent accepts the canonical
  issue and dismisses the duplicate with a reason. The duplicate becomes
  :dismissed (resolution captured); the canonical remains :accepted.

  Surface: `accept_issue` and `dismiss_issue` MCP tools.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.DismissIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dismiss requires a resolution" do
    scenario "Agent dismisses a duplicate with a reason naming the canonical issue" do
      given_ "two incoming issues describe the same underlying problem", context do
        scope = context.scope

        canonical =
          Fixtures.issue_fixture(scope, %{
            severity: :high,
            title: "Login fails on Safari — canonical"
          })

        duplicate =
          Fixtures.issue_fixture(scope, %{
            severity: :medium,
            title: "Login fails on Safari — duplicate"
          })

        {:ok, Map.merge(context, %{canonical: canonical, duplicate: duplicate})}
      end

      given_ "the agent has already accepted the canonical issue", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          AcceptIssue.execute(%{issue_id: context.canonical.id}, frame)

        {:ok, context}
      end

      when_ "the agent calls dismiss_issue on the duplicate with a reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        reason = "duplicate of issue #{context.canonical.id}"

        {:reply, response, _frame} =
          DismissIssue.execute(
            %{issue_id: context.duplicate.id, reason: reason},
            frame
          )

        {:ok, Map.put(context, :dismiss_response, response)}
      end

      then_ "the duplicate's status becomes :dismissed", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetIssue.execute(%{issue_id: context.duplicate.id}, frame)

        body = response_text(get_response)

        assert body =~ ~r/dismissed/i,
               "expected the duplicate to be :dismissed, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the duplicate's resolution captures the reason", context do
        body = response_text(context.dismiss_response)

        assert body =~ ~r/dismissed/i,
               "expected dismiss confirmation, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the canonical issue remains :accepted", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetIssue.execute(%{issue_id: context.canonical.id}, frame)

        body = response_text(get_response)

        assert body =~ ~r/accepted/i,
               "expected the canonical to remain :accepted, got: #{inspect(body)}"

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
