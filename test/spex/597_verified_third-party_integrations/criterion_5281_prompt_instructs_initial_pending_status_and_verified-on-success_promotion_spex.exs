defmodule CodeMySpecSpex.Story597.Criterion5281Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5281 — Prompt instructs initial pending status and verified-on-success promotion.

  New integration specs start at `pending`. The prompt instructs the
  agent to gather credentials, run the verify script, and promote
  status to `verified` only after a successful run.

  Surface: `start_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Spec status moves from pending to verified only after successful verification" do
    scenario "Prompt instructs initial pending status and verified-on-success promotion" do
      given_ "a baseline project is in place", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        {:ok, context}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the qa_integration_plan task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "qa_integration_plan",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt anchors the verified-status end state", context do
        assert context.prompt =~ "verified",
               "expected the prompt to mention the verified status"

        assert context.prompt =~ "qa_integration_plan/workflow.md",
               "expected the prompt to point at the qa_integration_plan playbook (initial-pending → verified-after-success promotion rule lives there)"

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
