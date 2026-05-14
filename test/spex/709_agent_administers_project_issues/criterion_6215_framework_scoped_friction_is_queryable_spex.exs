defmodule CodeMySpecSpex.Story709.Criterion6215Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6215 — Framework-scoped friction (problems with CodeMySpec
  itself: looping hooks, contradictory prompts, missing docs) lands as
  a `:framework` issue and is queryable separately from app issues.

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

  spex "Framework-scoped friction is recorded and queryable" do
    scenario "framework issue surfaces only when filtering by scope=framework" do
      given_ "an app-scoped issue exists for comparison", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateIssue.execute(
            %{
              title: "Dashboard count off-by-one",
              severity: "medium",
              scope: "app",
              description: "Header count shows one more than the rendered list."
            },
            frame
          )

        refute response.isError, "expected app issue to be created"

        {:ok, Map.put(context, :app_issue_id, extract_issue_id(response))}
      end

      when_ "the agent reports framework friction via create_issue with scope framework",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          title: "Stop hook loops on empty test_output_files",
          severity: "high",
          scope: "framework",
          description: "Hook re-fires without re-running compile when payload is empty."
        }

        {:reply, response, _frame} = CreateIssue.execute(params, frame)

        refute response.isError,
               "expected framework create_issue to succeed, got: #{inspect(response)}"

        {:ok,
         Map.merge(context, %{
           framework_issue_id: extract_issue_id(response),
           create_response: response
         })}
      end

      then_ "list_issues filtered by scope=framework returns the framework issue only", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListIssues.execute(%{scope: "framework"}, frame)
        body = response_text(response)

        assert body =~ "Stop hook loops on empty test_output_files",
               "expected framework issue title in framework-filtered list, got: #{inspect(body)}"

        refute body =~ "Dashboard count off-by-one",
               "expected app issue to be excluded from framework filter, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "list_issues filtered by scope=app excludes the framework issue", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListIssues.execute(%{scope: "app"}, frame)
        body = response_text(response)

        assert body =~ "Dashboard count off-by-one",
               "expected app issue in app-filtered list, got: #{inspect(body)}"

        refute body =~ "Stop hook loops on empty test_output_files",
               "expected framework issue to be excluded from app filter, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue on the framework issue reports its scope", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          GetIssue.execute(%{issue_id: context.framework_issue_id}, frame)

        body = response_text(response)

        assert body =~ "Stop hook loops on empty test_output_files",
               "expected title in get output, got: #{inspect(body)}"

        assert body =~ ~r/framework/i,
               "expected scope framework to appear in get output, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
