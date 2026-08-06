defmodule CodeMySpecSpex.Story858.Criterion7312Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7312 — Setup leaves backups running and monitors watching.

  Backups and uptime monitoring are part of setup, not an afterthought:
  the plan installs a scheduled database backup with a retention policy
  landing in the user's storage, and an uptime monitor for every public
  domain, before the requirement reads satisfied.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Setup leaves backups running and monitors watching" do
    scenario "the setup prompt installs backups and uptime monitors" do
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

      then_ "a scheduled database backup with retention is part of the plan", context do
        assert context.prompt =~ ~r/backup/i, "expected database backups in the setup plan"

        assert context.prompt =~ ~r/retention|expir|rolling/i,
               "expected a retention policy on the backups"

        {:ok, context}
      end

      and_ "an uptime monitor exists for every public domain", context do
        assert context.prompt =~ ~r/uptime|monitor/i,
               "expected uptime monitoring per public domain in the setup plan"

        {:ok, context}
      end
    end
  end
end
