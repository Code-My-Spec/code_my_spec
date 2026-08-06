defmodule CodeMySpecSpex.Story858.Criterion7303Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7303 — Sam sees every resource in his own consoles.

  Everything the agent provisions — server, secrets, buckets, DNS —
  lives in the user's own Hetzner/AWS/Cloudflare accounts; nothing is
  held on the platform's side. The task prompt carries that ownership
  contract.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Sam sees every resource in his own consoles" do
    scenario "the setup prompt provisions into the user's own accounts only" do
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

      then_ "the prompt requires provisioning into the user's own accounts", context do
        assert context.prompt =~ ~r/(user'?s|their) own account/i,
               "expected the ownership contract — resources live in the user's own accounts"

        {:ok, context}
      end

      and_ "the prompt never routes infrastructure through platform-held accounts", context do
        # Anchor: the prompt names the account providers it provisions into.
        assert context.prompt =~ "Hetzner"
        refute context.prompt =~ ~r/CodeMySpec('s)? (account|infrastructure|servers)/i

        {:ok, context}
      end
    end
  end
end
