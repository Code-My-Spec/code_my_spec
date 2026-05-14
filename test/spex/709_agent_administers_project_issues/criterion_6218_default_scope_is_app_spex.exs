defmodule CodeMySpecSpex.Story709.Criterion6218Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6218 — When the agent calls `create_issue` without a
  `scope` field, the issue is created with scope `:app`. The default
  must hold so a missing scope never silently lands under a different
  category.

  Surface: `create_issue`, `list_issues`, `get_issue` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Default scope is :app when scope is omitted" do
    scenario "an issue created without scope lands as :app" do
      when_ "the agent calls create_issue with no scope field", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          title: "Toast disappears too quickly",
          severity: "low",
          description: "Confirmation toast vanishes before it can be read."
        }

        {:reply, response, _frame} = CreateIssue.execute(params, frame)

        refute response.isError,
               "expected create_issue with no scope to succeed, got: #{inspect(response)}"

        {:ok,
         Map.merge(context, %{
           issue_id: extract_issue_id(response),
           create_response: response
         })}
      end

      then_ "get_issue reports the issue as :app scope", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetIssue.execute(%{issue_id: context.issue_id}, frame)

        body = response_text(response)

        assert body =~ "Toast disappears too quickly",
               "expected title in get output, got: #{inspect(body)}"

        assert body =~ ~r/Scope:\*+\s+app\b/i,
               "expected scope app in get output, got: #{inspect(body)}"

        refute body =~ ~r/Scope:\*+\s+framework\b/i,
               "did not expect framework scope on an unscoped issue, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "list_issues filtered by scope=app includes the issue", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListIssues.execute(%{scope: "app"}, frame)
        body = response_text(response)

        assert body =~ "Toast disappears too quickly",
               "expected default-scoped issue in app filter, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "list_issues filtered by scope=qa excludes the issue", context do
        # The local list_issues surface refuses scope=framework on purpose
        # (framework issues live server-side, not locally), so we use
        # scope=qa here to prove the default-scoped issue lands as :app
        # and is filtered out of any other local scope.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListIssues.execute(%{scope: "qa"}, frame)
        body = response_text(response)

        refute body =~ "Toast disappears too quickly",
               "expected default-scoped issue to NOT appear in qa filter, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
