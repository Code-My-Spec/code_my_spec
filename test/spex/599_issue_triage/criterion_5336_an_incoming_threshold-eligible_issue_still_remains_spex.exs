defmodule CodeMySpecSpex.Story599.Criterion5336Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5336 — An incoming threshold-eligible issue still remains.

  When evaluate_task is called and at least one incoming issue at or above
  the threshold has not been dispositioned, the evaluator returns :invalid,
  names the remaining issue in feedback, and instructs the agent to use
  accept_issue or dismiss_issue.

  Surface: `start_task` + `evaluate_task` MCP tools.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.IssuesFixtures
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Triage completes only when no threshold-eligible incoming issues remain" do
    scenario "An incoming threshold-eligible issue still remains" do
      given_ "the project has 2 incoming issues at or above the threshold", context do
        scope = context.scope

        issue_a = IssuesFixtures.issue_fixture(scope, %{severity: :high, title: "Triaged issue"})
        issue_b = IssuesFixtures.issue_fixture(scope, %{severity: :medium, title: "Remaining issue"})

        {:ok, Map.merge(context, %{issue_a: issue_a, issue_b: issue_b})}
      end

      given_ "a triage task is started", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "issues_triaged",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: session_id
            },
            frame
          )

        task_id = extract_task_id(response_text(response))
        {:ok, Map.merge(context, %{session_id: session_id, task_id: task_id})}
      end

      given_ "the agent has dispositioned only 1 of the 2 issues", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _r, _f} = AcceptIssue.execute(%{issue_id: context.issue_a.id}, frame)

        # issue_b is intentionally left :incoming
        {:ok, context}
      end

      when_ "the operator calls evaluate_task on the triage task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :evaluate_response, response)}
      end

      then_ "the task evaluator returns :invalid", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/needs work|invalid/i,
               "expected a needs-work response, got: #{inspect(body)}"

        :ok
      end

      then_ "the feedback names the remaining incoming issue", context do
        body = response_text(context.evaluate_response)

        assert body =~ context.issue_b.title,
               "expected feedback to name the remaining issue '#{context.issue_b.title}', got: #{inspect(body)}"

        :ok
      end

      then_ "the feedback instructs the agent to use accept_issue or dismiss_issue", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/accept_issue|dismiss_issue/,
               "expected feedback to reference accept_issue or dismiss_issue, got: #{inspect(body)}"

        :ok
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

  defp extract_task_id(text) do
    case Regex.run(~r/Task ID: `([^`]+)`/, text) do
      [_, task_id] -> task_id
      _ -> raise "Could not extract task ID from response: #{inspect(text)}"
    end
  end
end
