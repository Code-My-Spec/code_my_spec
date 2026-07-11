defmodule CodeMySpecSpex.Story858.Criterion7302Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7302 — An under-scoped token names its missing permission.

  When a supplied credential can't perform a provisioning step, setup
  halts that step before any partial provisioning and reports exactly
  which credential needs which permission. The task prompt carries that
  failure contract so the agent never half-provisions on authorization
  errors.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An under-scoped token names its missing permission" do
    scenario "the setup prompt carries the halt-and-name failure contract" do
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

      then_ "the prompt instructs halting on permission errors before partial provisioning", context do
        assert context.prompt =~ ~r/halt|stop|do not (continue|proceed)/i,
               "expected a halt instruction for authorization failures"

        assert context.prompt =~ ~r/permission|scope|authoriz/i,
               "expected the failure contract to be about credential permissions"

        {:ok, context}
      end

      and_ "the prompt requires naming the credential and the permission it lacks", context do
        assert context.prompt =~ ~r/(which|name[s]?( the)?) credential/i,
               "expected the prompt to require naming the failing credential"

        {:ok, context}
      end
    end
  end
end
