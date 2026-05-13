defmodule CodeMySpecSpex.Story599.Criterion5330Spex do
  @moduledoc """
  Story 599 — Issue Triage
  Criterion 5330 — Below-threshold issue is incorrectly surfaced.

  When the task runs with the default :medium threshold, a :low issue must
  NOT appear in the triage prompt. The prompt's stated threshold must read
  :medium (or equivalent).

  Surface: `start_task` for the `issues_triaged` project requirement.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
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
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the operator starts a triage task with the default threshold :medium", context do
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

      then_ "the prompt does not list the low issue", context do
        prompt = context.triage_prompt
        low_issue = context.low_issue

        refute prompt =~ low_issue.id,
               "expected prompt to exclude the low-severity issue #{low_issue.id}, but found it in: #{inspect(prompt)}"

        {:ok, context}
      end

      then_ "the prompt's stated threshold reads medium", context do
        prompt = context.triage_prompt

        assert prompt =~ ~r/medium/i,
               "expected the prompt to mention the :medium threshold, got: #{inspect(prompt)}"

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
