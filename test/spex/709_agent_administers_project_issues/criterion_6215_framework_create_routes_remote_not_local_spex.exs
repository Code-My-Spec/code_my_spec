defmodule CodeMySpecSpex.Story709.Criterion6215Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6215 — Framework-scoped friction routes to the CodeMySpec
  server and never lands in the local CLI's DB.

  The agent's only contract with framework issues is `create_issue`
  with `scope: framework` (fire-and-forget). After creation, framework
  issues are administered server-side; the local MCP `list_issues`
  surface intentionally does not expose them, and the local DB never
  holds a framework-scoped row.

  Surface: `create_issue` and `list_issues` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Fixtures.reset_framework_issue_stub()
    :ok
  end

  spex "Framework create routes to the server and stays out of the local DB" do
    scenario "create with scope=framework is captured remotely and absent locally" do
      given_ "an unrelated app-scoped issue exists for contrast", context do
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

        {:ok, context}
      end

      when_ "the agent reports framework friction via create_issue with scope=framework",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateIssue.execute(
            %{
              title: "Stop hook loops on empty test_output_files",
              severity: "high",
              scope: "framework",
              description: "Hook re-fires without re-running compile when payload is empty."
            },
            frame
          )

        refute response.isError,
               "expected framework create_issue to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :create_response, response)}
      end

      then_ "the create response confirms the framework issue was recorded", context do
        body = response_text(context.create_response)

        assert body =~ "Stop hook loops on empty test_output_files",
               "expected framework title in response, got: #{inspect(body)}"

        assert body =~ ~r/ID:\s*[^\)\s]+/,
               "expected an issue id in the response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the framework write reached the remote surface (captured by the stub)",
            context do
        captured = Fixtures.captured_framework_issues()

        titles = Enum.map(captured, & &1.title)

        assert "Stop hook loops on empty test_output_files" in titles,
               "expected the framework issue to be captured remotely, got titles: #{inspect(titles)}"

        framework_only? = Enum.all?(captured, &(&1.scope == :framework))

        assert framework_only?,
               "expected every captured remote issue to be scope=framework, got: #{inspect(captured)}"

        {:ok, context}
      end

      then_ "the local list_issues surface excludes the framework issue and includes the app one",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListIssues.execute(%{}, frame)
        body = response_text(response)

        assert body =~ "Dashboard count off-by-one",
               "expected the app issue to appear in local listings, got: #{inspect(body)}"

        refute body =~ "Stop hook loops on empty test_output_files",
               "framework issues must NOT appear in the local DB, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "list_issues rejects scope=framework as an invalid filter on the local surface",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListIssues.execute(%{scope: "framework"}, frame)

        assert response.isError,
               "local list_issues must refuse scope=framework, got: #{inspect(response)}"

        {:ok, context}
      end
    end
  end
end
