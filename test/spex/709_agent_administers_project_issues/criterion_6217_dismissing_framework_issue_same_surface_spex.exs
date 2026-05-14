defmodule CodeMySpecSpex.Story709.Criterion6217Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6217 — Dismissing a framework-scoped issue uses the same
  `dismiss_issue` surface as an app issue. No special framework-only
  dismissal tool exists; the agent invokes the same MCP call with the
  same shape.

  Surface: `create_issue`, `dismiss_issue`, `get_issue` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.DismissIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Dismissing a framework issue uses the same surface as an app issue" do
    scenario "dismiss closes a framework issue and records the reason" do
      given_ "an incoming framework issue exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateIssue.execute(
            %{
              title: "Duplicate framework friction report",
              severity: "low",
              scope: "framework",
              description: "Already filed as another framework issue last week."
            },
            frame
          )

        refute response.isError, "expected framework create_issue to succeed"

        {:ok, Map.put(context, :issue_id, extract_issue_id(response))}
      end

      when_ "the agent dismisses the framework issue with a reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          issue_id: context.issue_id,
          reason: "Duplicate of the earlier framework friction report."
        }

        {:reply, response, _frame} = DismissIssue.execute(params, frame)

        refute response.isError,
               "expected dismiss on a framework issue to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :dismiss_response, response)}
      end

      then_ "the response confirms dismissal", context do
        body = response_text(context.dismiss_response)

        assert body =~ ~r/dismissed/i,
               "expected dismissal confirmation, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue shows dismissed status with the reason and framework scope", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        body = response_text(response)

        assert body =~ ~r/dismissed/i,
               "expected status dismissed, got: #{inspect(body)}"

        assert body =~ "Duplicate of the earlier framework friction report",
               "expected dismissal reason recorded, got: #{inspect(body)}"

        assert body =~ ~r/framework/i,
               "expected framework scope to appear in get output, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
