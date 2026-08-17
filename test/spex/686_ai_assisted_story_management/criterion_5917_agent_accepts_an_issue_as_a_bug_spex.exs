defmodule CodeMySpecSpex.Story686.Criterion5917Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 5917 — Agent accepts an incoming issue as a bug, with no
  story link. The issue closes with category `bug` and is recorded for
  later resolution.

  Surface: `create_issue`, `accept_issue`, `get_issue` MCP tools.

  Overlaps with Story 599 / Criterion 5331 (which exercises
  `accept_issue` with `category: "bug"` as well). Kept here so that the
  PM-server contract is independently asserted from this story's
  perspective.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Accept an issue as a bug without a story link" do
    scenario "Issue closes with category bug and no story is referenced" do
      given_ "an incoming issue exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateIssue.execute(
            %{
              title: "Stop hook stalls on retry",
              severity: "high",
              description: "Stop hook hangs when retried after a timeout."
            },
            frame
          )

        issue_id = extract_issue_id(response)

        {:ok, Map.put(context, :issue_id, issue_id)}
      end

      when_ "the agent accepts the issue with category bug and no story_id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{issue_id: context.issue_id, category: "bug"}

        {:reply, response, _frame} = AcceptIssue.execute(params, frame)

        refute response.isError,
               "expected accept_issue to succeed without a story link, got: #{inspect(response)}"

        {:ok, Map.put(context, :accept_response, response)}
      end

      then_ "the response confirms acceptance with the bug disposition", context do
        body = response_text(context.accept_response)

        assert body =~ ~r/accepted/i,
               "expected acceptance confirmation, got: #{inspect(body)}"

        assert body =~ ~r/bug/i,
               "expected bug category in response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue reflects the new status and no story link", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, get_response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        body = response_text(get_response)

        assert body =~ ~r/accepted/i,
               "expected issue status accepted, got: #{inspect(body)}"

        assert body =~ ~r/bug/i,
               "expected category bug visible in get_issue, got: #{inspect(body)}"

        refute body =~ ~r/Story:\s*\d+/,
               "expected no story link recorded, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
