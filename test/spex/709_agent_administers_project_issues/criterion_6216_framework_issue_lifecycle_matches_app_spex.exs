defmodule CodeMySpecSpex.Story709.Criterion6216Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6216 — A framework-scoped issue moves through the same
  create → accept → resolve lifecycle as an app issue, with no special
  surface or tool.

  Surface: `create_issue`, `accept_issue`, `resolve_issue`, `get_issue`
  MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Issues.Tools.ResolveIssue

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Framework issue follows the same lifecycle as an app issue" do
    scenario "create → accept → resolve closes the framework issue end-to-end" do
      given_ "an incoming framework issue exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateIssue.execute(
            %{
              title: "MCP tool returns confusing error on missing scope",
              severity: "medium",
              scope: "framework",
              description: "Error message names a field that isn't documented."
            },
            frame
          )

        refute response.isError, "expected framework create_issue to succeed"

        {:ok, Map.put(context, :issue_id, extract_issue_id(response))}
      end

      when_ "the agent accepts and resolves the framework issue", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, accept_response, _frame} =
          AcceptIssue.execute(
            %{issue_id: context.issue_id, category: "bug"},
            frame
          )

        refute accept_response.isError,
               "expected accept on a framework issue to succeed, got: #{inspect(accept_response)}"

        {:reply, resolve_response, _frame} =
          ResolveIssue.execute(
            %{
              issue_id: context.issue_id,
              resolution: "Improved error message and added scope documentation."
            },
            frame
          )

        refute resolve_response.isError,
               "expected resolve on a framework issue to succeed, got: #{inspect(resolve_response)}"

        {:ok,
         Map.merge(context, %{
           accept_response: accept_response,
           resolve_response: resolve_response
         })}
      end

      then_ "accept confirms acceptance and resolve confirms resolution", context do
        accept_body = response_text(context.accept_response)
        resolve_body = response_text(context.resolve_response)

        assert accept_body =~ ~r/accepted/i,
               "expected accept confirmation, got: #{inspect(accept_body)}"

        assert resolve_body =~ ~r/resolved/i,
               "expected resolve confirmation, got: #{inspect(resolve_body)}"

        {:ok, context}
      end

      then_ "get_issue shows resolved status, the resolution note, and framework scope",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        body = response_text(response)

        assert body =~ ~r/resolved/i,
               "expected final status resolved, got: #{inspect(body)}"

        assert body =~ "Improved error message",
               "expected resolution note recorded, got: #{inspect(body)}"

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
