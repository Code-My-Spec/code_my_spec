defmodule CodeMySpecSpex.Story599.Criterion5330Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5330 — Below-threshold issue is incorrectly surfaced.

  Under the tool-driven model, a :low incoming issue must NOT appear
  enumerated in the triage prompt. `list_issues` still exposes the
  issue (so the agent can discover it if it ever lowers the threshold),
  but the prompt declares the :medium threshold so the agent skips it
  during triage.

  Surface: `start_task` for the `issues_triaged` project requirement,
  then `list_issues` against the local MCP server.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Triage operates only on issues at or above a severity threshold" do
    scenario "Below-threshold issue is incorrectly surfaced" do
      given_ "the project has only a low severity incoming issue", context do
        scope = context.scope
        low_issue = Fixtures.issue_fixture(scope, %{severity: :low, title: "Low severity issue"})
        {:ok, Map.put(context, :low_issue, low_issue)}
      end

      given_ "a session is started", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the operator starts a triage task with the default threshold", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "issues_triaged",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :triage_prompt, response_text(response))}
      end

      when_ "the agent calls list_issues for the low severity", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListIssues.execute(%{status: "incoming", severity: "low"}, frame)

        {:ok, Map.put(context, :low_list_text, response_text(response))}
      end

      then_ "the triage prompt declares the threshold is medium", context do
        assert context.triage_prompt =~ ~r/medium/i,
               "expected the triage prompt to declare :medium threshold, got: #{inspect(context.triage_prompt)}"

        {:ok, context}
      end

      then_ "the triage prompt does not enumerate the low issue", context do
        refute context.triage_prompt =~ context.low_issue.id,
               "expected triage prompt to NOT enumerate :low issue #{context.low_issue.id} under the tool-driven model, got: #{inspect(context.triage_prompt)}"

        {:ok, context}
      end

      then_ "list_issues(severity: low) returns the low issue for agent discovery", context do
        assert context.low_list_text =~ context.low_issue.id,
               "expected list_issues(severity: low) to expose the :low issue #{context.low_issue.id} (the surface stays discoverable; the prompt-declared threshold tells the agent to skip it during triage), got: #{inspect(context.low_list_text)}"

        {:ok, context}
      end
    end
  end
end
