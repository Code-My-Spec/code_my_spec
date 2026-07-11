defmodule CodeMySpecSpex.Story858.Criterion7309Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7309 — Secrets are seeded once and fetched at boot.

  App secrets are seeded into the user's secrets store and fetched by
  the app at startup — the SSM-bootstrap pattern. Neither the repo nor
  the deploy tool ever carries a secret value; the deploy configuration
  holds only the bootstrap credentials needed to reach the store.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Secrets are seeded once and fetched at boot" do
    scenario "the setup prompt mandates the store-and-boot-fetch secrets pattern" do
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

      then_ "secrets are seeded to a store and fetched by the app at boot", context do
        assert context.prompt =~ ~r/secrets? store|parameter store|SSM/i,
               "expected a secrets store in the plan"

        assert context.prompt =~ ~r/(fetch|load).*(boot|startup)/i,
               "expected the app to fetch its secrets at boot"

        {:ok, context}
      end

      and_ "no secret value lives in the repo or passes through the deploy tool", context do
        assert context.prompt =~ ~r/never.*(repo|repository|deploy)|no secrets? .*(repo|deploy)/i,
               "expected an explicit no-secrets-in-repo/deploy-tool contract"

        {:ok, context}
      end
    end
  end
end
