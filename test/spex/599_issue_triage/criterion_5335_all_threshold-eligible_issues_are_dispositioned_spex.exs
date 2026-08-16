defmodule CodeMySpecSpex.Story599.Criterion5335Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5335 — All threshold-eligible issues are dispositioned.

  When every incoming issue at or above the threshold has been either
  accepted or dismissed, calling evaluate_task on the triage task returns
  :valid and the task transitions to :completed.

  Surface: `start_task` (creates the triage task), `accept_issue` /
  `dismiss_issue` (dispositions), then `evaluate_task`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.DismissIssue
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Triage completes only when no threshold-eligible incoming issues remain" do
    scenario "All threshold-eligible issues are dispositioned" do
      given_ "the project has 3 incoming issues at or above the threshold", context do
        scope = context.scope

        issue_a = Fixtures.issue_fixture(scope, %{severity: :high, title: "Triage issue A"})
        issue_b = Fixtures.issue_fixture(scope, %{severity: :medium, title: "Triage issue B"})
        issue_c = Fixtures.issue_fixture(scope, %{severity: :high, title: "Triage issue C"})

        {:ok, Map.merge(context, %{issue_a: issue_a, issue_b: issue_b, issue_c: issue_c})}
      end

      given_ "a triage task is started", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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

      given_ "the agent has accepted 2 as bugs and dismissed 1 with a reason", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _r, _f} = AcceptIssue.execute(%{issue_id: context.issue_a.id}, frame)
        {:reply, _r, _f} = AcceptIssue.execute(%{issue_id: context.issue_b.id}, frame)

        {:reply, _r, _f} =
          DismissIssue.execute(
            %{issue_id: context.issue_c.id, reason: "not reproducible — expected behavior"},
            frame
          )

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

      then_ "the task evaluator returns :valid", context do
        body = response_text(context.evaluate_response)

        refute body =~ ~r/needs work|invalid/i,
               "expected evaluate to pass, got: #{inspect(body)}"

        assert body =~ ~r/passed|completed|satisfied|valid/i,
               "expected a passing evaluate response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the task transitions to :completed", context do
        body = response_text(context.evaluate_response)

        assert body =~ ~r/passed|completed/i,
               "expected task to be marked completed, got: #{inspect(body)}"

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

  defp extract_task_id(text), do: extract_task_id_from(Regex.run(~r/Task ID: `([^`]+)`/, text), text)

  defp extract_task_id_from([_, task_id], _text), do: task_id
  defp extract_task_id_from(_, text), do: raise("Could not extract task ID from response: #{inspect(text)}")
end
