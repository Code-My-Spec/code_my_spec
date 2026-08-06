defmodule CodeMySpecSpex.Story858.Criterion7310Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7310 — A missing secret fails the boot loudly and by name.

  The secrets-at-boot pattern must fail fast: when a required key is
  absent from the store, the app refuses to start and names the missing
  key, rather than booting half-configured. The setup task carries that
  contract for the Secrets module it installs in the target app.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A missing secret fails the boot loudly and by name" do
    scenario "the setup prompt requires fail-fast boot on missing secrets" do
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

      then_ "a missing required secret fails the boot naming the key", context do
        assert context.prompt =~ ~r/fail[s]?[- ]fast|refuse[s]? to (start|boot)/i,
               "expected a fail-fast boot contract for missing secrets"

        assert context.prompt =~ ~r/(nam(e|ing)|missing) (the )?(key|secret)/i,
               "expected the failure to name the missing key"

        {:ok, context}
      end
    end
  end
end
