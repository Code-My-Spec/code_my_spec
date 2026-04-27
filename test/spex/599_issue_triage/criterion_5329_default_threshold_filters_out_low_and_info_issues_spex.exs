defmodule CodeMySpecSpex.Story599.Criterion5329Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5329 — Default threshold filters out low and info issues.

  When no override is given, the triage task prompt lists only issues at
  :medium or above — :high and :medium items appear, :low and :info are
  absent. Severity threshold defaults to :medium per Rule 1.

  Surface: `start_task` for the `issues_triaged` project requirement.
  The triage prompt returned by the tool must enumerate only the
  threshold-eligible issues.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.IssuesFixtures
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Triage operates only on issues at or above a severity threshold" do
    scenario "Default threshold filters out low and info issues" do
      given_ "the project has incoming issues at multiple severities", context do
        scope = context.scope

        high_1 = IssuesFixtures.issue_fixture(scope, %{severity: :high, title: "High issue one"})
        high_2 = IssuesFixtures.issue_fixture(scope, %{severity: :high, title: "High issue two"})
        med_1 = IssuesFixtures.issue_fixture(scope, %{severity: :medium, title: "Medium issue one"})
        med_2 = IssuesFixtures.issue_fixture(scope, %{severity: :medium, title: "Medium issue two"})
        med_3 = IssuesFixtures.issue_fixture(scope, %{severity: :medium, title: "Medium issue three"})
        low_1 = IssuesFixtures.issue_fixture(scope, %{severity: :low, title: "Low issue one"})
        low_2 = IssuesFixtures.issue_fixture(scope, %{severity: :low, title: "Low issue two"})
        low_3 = IssuesFixtures.issue_fixture(scope, %{severity: :low, title: "Low issue three"})
        low_4 = IssuesFixtures.issue_fixture(scope, %{severity: :low, title: "Low issue four"})
        info_1 = IssuesFixtures.issue_fixture(scope, %{severity: :info, title: "Info issue one"})

        {:ok,
         Map.merge(context, %{
           high_issues: [high_1, high_2],
           medium_issues: [med_1, med_2, med_3],
           low_issues: [low_1, low_2, low_3, low_4],
           info_issues: [info_1]
         })}
      end

      given_ "a session is started", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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

      then_ "the agent's prompt lists the high and medium issues", context do
        prompt = context.triage_prompt

        for issue <- context.high_issues ++ context.medium_issues do
          assert prompt =~ issue.id,
                 "expected prompt to include issue #{issue.id} (#{issue.severity}), got: #{inspect(prompt)}"
        end

        {:ok, context}
      end

      then_ "no low or info issues appear in the prompt", context do
        prompt = context.triage_prompt

        for issue <- context.low_issues ++ context.info_issues do
          refute prompt =~ issue.id,
                 "expected prompt to exclude issue #{issue.id} (#{issue.severity}), but it appears in: #{inspect(prompt)}"
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
