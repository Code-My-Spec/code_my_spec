defmodule CodeMySpecSpex.Story597.Criterion5278Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5278 — Project with no decision records points the agent back at technical_strategy and offers an empty index.

  When ADRs are absent, the prompt names technical_strategy as the
  upstream step and offers writing an empty integration index as the
  no-integrations escape hatch.

  Surface: `start_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Integration specs are derived from technical decisions" do
    scenario "Project with no decision records points the agent back at technical_strategy and offers an empty index" do
      given_ "the project has no decision records on disk", context do
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

      then_ "the prompt names technical_strategy as the upstream step to complete first",
            context do
        assert context.prompt =~ ~r/technical strategy/i,
               "expected the prompt to point at the technical_strategy step"

        {:ok, context}
      end

      and_ "the prompt offers writing an empty integration index when no integrations are needed",
           context do
        assert context.prompt =~ ~r/no integrations/i,
               "expected the prompt to mention the no-integrations escape hatch"

        assert context.prompt =~ ~r/(empty|no integrations).*index|index.*no integrations/is,
               "expected the prompt to mention writing an empty integration index"

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
