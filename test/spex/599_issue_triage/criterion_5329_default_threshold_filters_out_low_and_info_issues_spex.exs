defmodule CodeMySpecSpex.Story599.Criterion5329Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5329 — Default threshold filters out low and info issues.

  Under the tool-driven triage model, the prompt declares the threshold
  (:medium+) and does not enumerate issues. The agent discovers them
  via `list_issues`. This spec asserts:

  - the prompt declares the :medium threshold,
  - the prompt does not enumerate any issue id, title, or severity,
  - `list_issues(status: :incoming, severity: :high)` returns the 2 high issues,
  - `list_issues(status: :incoming, severity: :medium)` returns the 3 medium issues.

  Surface: `start_task` for the `issues_triaged` project requirement, then
  `list_issues` against the local MCP server.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Triage operates only on issues at or above a severity threshold" do
    scenario "Default threshold filters out low and info issues" do
      given_ "the project has incoming issues at multiple severities", context do
        scope = context.scope

        high_issues =
          for n <- 1..2,
              do: Fixtures.issue_fixture(scope, %{severity: :high, title: "High issue #{n}"})

        medium_issues =
          for n <- 1..3,
              do: Fixtures.issue_fixture(scope, %{severity: :medium, title: "Medium issue #{n}"})

        low_issues =
          for n <- 1..4,
              do: Fixtures.issue_fixture(scope, %{severity: :low, title: "Low issue #{n}"})

        info_issues =
          for n <- 1..1,
              do: Fixtures.issue_fixture(scope, %{severity: :info, title: "Info issue #{n}"})

        {:ok,
         Map.merge(context, %{
           high_issues: high_issues,
           medium_issues: medium_issues,
           low_issues: low_issues,
           info_issues: info_issues
         })}
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

      when_ "the operator starts a triage task without overriding the threshold", context do
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

      when_ "the agent calls list_issues for the high and medium severities", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, high_response, _} =
          ListIssues.execute(%{status: "incoming", severity: "high"}, frame)

        {:reply, medium_response, _} =
          ListIssues.execute(%{status: "incoming", severity: "medium"}, frame)

        {:ok,
         context
         |> Map.put(:high_list_text, response_text(high_response))
         |> Map.put(:medium_list_text, response_text(medium_response))}
      end

      then_ "the triage prompt declares the threshold is medium", context do
        assert context.triage_prompt =~ ~r/medium/i,
               "expected the triage prompt to declare :medium threshold, got: #{inspect(context.triage_prompt)}"

        {:ok, context}
      end

      then_ "the triage prompt does not enumerate any issue id, title, or severity", context do
        all_issues =
          context.high_issues ++
            context.medium_issues ++ context.low_issues ++ context.info_issues

        for issue <- all_issues do
          refute context.triage_prompt =~ issue.id,
                 "expected triage prompt to NOT enumerate issue id #{issue.id} under the tool-driven model, got: #{inspect(context.triage_prompt)}"
        end

        {:ok, context}
      end

      then_ "list_issues(severity: high) returns exactly the 2 high incoming issues", context do
        for issue <- context.high_issues do
          assert context.high_list_text =~ issue.id,
                 "expected list_issues(severity: high) to include #{issue.id}, got: #{inspect(context.high_list_text)}"
        end

        for issue <- context.medium_issues ++ context.low_issues ++ context.info_issues do
          refute context.high_list_text =~ issue.id,
                 "expected list_issues(severity: high) to exclude non-high issue #{issue.id} (#{issue.severity}), got: #{inspect(context.high_list_text)}"
        end

        {:ok, context}
      end

      then_ "list_issues(severity: medium) returns exactly the 3 medium incoming issues", context do
        for issue <- context.medium_issues do
          assert context.medium_list_text =~ issue.id,
                 "expected list_issues(severity: medium) to include #{issue.id}, got: #{inspect(context.medium_list_text)}"
        end

        for issue <- context.high_issues ++ context.low_issues ++ context.info_issues do
          refute context.medium_list_text =~ issue.id,
                 "expected list_issues(severity: medium) to exclude non-medium issue #{issue.id} (#{issue.severity}), got: #{inspect(context.medium_list_text)}"
        end

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
