defmodule CodeMySpecSpex.Story858.Criterion7308Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7308 — A failing UAT health check stops the promotion.

  The deploy directive gates prod on UAT's health: the agent must verify
  UAT's health check after deploying there and halt the promotion —
  surfacing the failure as a problem — rather than deploying prod on a
  sick UAT.

  Surface: `start_task` MCP tool against the loop's deploy requirement.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A failing UAT health check stops the promotion" do
    scenario "the deploy prompt gates prod on UAT health" do
      given_ "devops setup is complete and a story has passed QA", context do
        {:ok, FullSatisfactionFixtures.apply_without_deploy(context)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the deploy task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "deploy",
              entity_type: "story",
              entity_id: to_string(context.story.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt requires verifying UAT's health before prod", context do
        assert context.prompt =~ ~r/uat.*health.*prod/is,
               "expected the prompt to order UAT health verification before the prod deploy"

        {:ok, context}
      end

      and_ "a failing health check halts the promotion and surfaces the failure", context do
        assert context.prompt =~ ~r/(halt|stop|do not deploy prod)/i,
               "expected an explicit halt instruction on a failing UAT health check"

        {:ok, context}
      end
    end
  end
end
