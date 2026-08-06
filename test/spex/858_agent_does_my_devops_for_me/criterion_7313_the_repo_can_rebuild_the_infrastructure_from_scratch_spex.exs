defmodule CodeMySpecSpex.Story858.Criterion7313Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7313 — The repo can rebuild the infrastructure from scratch.

  Every infrastructure step is captured as re-runnable configuration or
  scripts checked into the repo — deploy configuration, provisioning
  scripts, secrets seeding — and re-running any of them is safe and
  idempotent. Nothing is done by hand that cannot be replayed.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The repo can rebuild the infrastructure from scratch" do
    scenario "the setup prompt captures every step as re-runnable repo artifacts" do
      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the devops_setup task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "devops_setup",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "deploy configuration and provisioning scripts are checked into the repo", context do
        assert context.prompt =~ ~r/check(ed)?[- ]in|commit/i,
               "expected infrastructure artifacts to be committed to the repo"

        assert context.prompt =~ ~r/script/i,
               "expected provisioning/deploy scripts among the artifacts"

        {:ok, context}
      end

      and_ "re-running any step is safe and idempotent", context do
        assert context.prompt =~ ~r/idempoten/i,
               "expected an idempotency contract on the infrastructure steps"

        refute context.prompt =~ ~r/by hand|manual step/i,
               "expected no unreplayable by-hand steps in the plan"

        {:ok, context}
      end
    end
  end
end
