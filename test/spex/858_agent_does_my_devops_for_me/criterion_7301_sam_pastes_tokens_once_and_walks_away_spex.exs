defmodule CodeMySpecSpex.Story858.Criterion7301Spex do
  @moduledoc """
  Story 858 — Agent does my DevOps for me
  Criterion 7301 — Sam pastes tokens once and walks away.

  The devops_setup task prompt collects the user's Hetzner, AWS, and
  Cloudflare credentials ONCE up front, then instructs the agent through
  the full pipeline — server, DNS, secrets, deploy — with no further
  user input beyond those credentials.

  Surface: `start_task` MCP tool against `devops_setup`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam pastes tokens once and walks away" do
    scenario "the setup prompt collects credentials once and covers the whole pipeline" do
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

      then_ "the prompt instructs collecting the three account credentials up front", context do
        for provider <- ["Hetzner", "AWS", "Cloudflare"] do
          assert context.prompt =~ provider,
                 "expected the prompt to name #{provider} among the credentials to collect"
        end

        {:ok, context}
      end

      and_ "the prompt covers the full pipeline without further user input", context do
        for step <- ["server", "DNS", "secrets", "deploy"] do
          assert context.prompt =~ ~r/#{step}/i,
                 "expected the prompt to cover the #{step} step"
        end

        assert context.prompt =~ ~r/without (further|additional|more) (input|questions)|only .* credentials/i,
               "expected the prompt to promise no user input beyond credentials"

        {:ok, context}
      end
    end
  end
end
