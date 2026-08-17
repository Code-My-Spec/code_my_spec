defmodule CodeMySpecSpex.Story709.Criterion6214Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6214 — Agent runs the full issue lifecycle end-to-end:
  create → list → get → accept → resolve, observed through the
  Issues MCP tools.

  Surface: `create_issue`, `list_issues`, `get_issue`, `accept_issue`,
  `resolve_issue` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.Issues.Tools.ResolveIssue

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent runs the full issue lifecycle through MCP tools" do
    scenario "create surfaces an issue id" do
      when_ "the agent calls create_issue with scope app", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          title: "Loading spinner flickers on dashboard",
          severity: "medium",
          scope: "app",
          description: "Spinner re-mounts twice when navigating to the dashboard."
        }

        {:reply, response, _frame} = CreateIssue.execute(params, frame)

        refute response.isError,
               "expected create_issue to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :create_response, response)}
      end

      then_ "the response carries an issue id and the title", context do
        body = response_text(context.create_response)

        assert body =~ "Loading spinner flickers on dashboard",
               "expected title in response, got: #{inspect(body)}"

        assert body =~ ~r/ID:\s*[^\)\s]+/,
               "expected an issue id in the response, got: #{inspect(body)}"

        {:ok, context}
      end
    end

    scenario "list, get, accept, and resolve operate on the same issue" do
      given_ "an incoming issue exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          title: "Settings save button stuck disabled",
          severity: "high",
          scope: "app",
          description: "Save button stays disabled after editing the API key."
        }

        {:reply, response, _frame} = CreateIssue.execute(params, frame)

        refute response.isError, "expected create_issue to succeed, got: #{inspect(response)}"

        issue_id = extract_issue_id(response)

        {:ok, Map.put(context, :issue_id, issue_id)}
      end

      when_ "the agent runs list → get → accept → resolve in order", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} = ListIssues.execute(%{}, frame)
        refute list_response.isError, "expected list_issues to succeed"

        {:reply, get_response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        refute get_response.isError, "expected get_issue to succeed"

        {:reply, accept_response, _frame} =
          AcceptIssue.execute(
            %{issue_id: context.issue_id, category: "bug"},
            frame
          )

        refute accept_response.isError, "expected accept_issue to succeed"

        {:reply, resolve_response, _frame} =
          ResolveIssue.execute(
            %{
              issue_id: context.issue_id,
              resolution: "Re-enabled save button after key changes; covered by a test."
            },
            frame
          )

        refute resolve_response.isError, "expected resolve_issue to succeed"

        {:ok,
         Map.merge(context, %{
           list_response: list_response,
           get_response: get_response,
           accept_response: accept_response,
           resolve_response: resolve_response
         })}
      end

      then_ "list_issues includes the issue by id and title", context do
        body = response_text(context.list_response)

        assert body =~ "Settings save button stuck disabled",
               "expected issue title in list output, got: #{inspect(body)}"

        assert body =~ context.issue_id,
               "expected issue id in list output, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue echoes the title and the id", context do
        body = response_text(context.get_response)

        assert body =~ "Settings save button stuck disabled",
               "expected title in get output, got: #{inspect(body)}"

        assert body =~ context.issue_id,
               "expected id in get output, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "accept_issue confirms acceptance with the bug disposition", context do
        body = response_text(context.accept_response)

        assert body =~ ~r/accepted/i,
               "expected acceptance confirmation, got: #{inspect(body)}"

        assert body =~ ~r/bug/i,
               "expected bug category in response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "resolve_issue confirms resolution and surfaces the resolution text", context do
        body = response_text(context.resolve_response)

        assert body =~ ~r/resolved/i,
               "expected resolution confirmation, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue after resolution reflects the resolved status and resolution note",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, final, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        body = response_text(final)

        assert body =~ ~r/resolved/i,
               "expected final status resolved, got: #{inspect(body)}"

        assert body =~ "Re-enabled save button",
               "expected resolution note recorded, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
