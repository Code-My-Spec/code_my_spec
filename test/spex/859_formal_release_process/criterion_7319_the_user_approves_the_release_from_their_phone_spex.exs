defmodule CodeMySpecSpex.Story859.Criterion7319Spex do
  @moduledoc """
  Story 859 — Formal release process
  Criterion 7319 — The user approves the release from their phone.

  A prod release requires the user's explicit approval before anything
  deploys: the prompt assembles the version + notes and demands an
  `ask_user` go-ahead (which reaches the user's phone via the remote
  question flow) before any deploy, tag, or publish.

  Surface: `start_task` MCP tool against `release`.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The user approves the release from their phone" do
    scenario "the release prompt gates every deploy on an explicit yes" do
      given_ "a story is deployed to UAT with no release covering it", context do
        {:ok, FullSatisfactionFixtures.apply_without_release(context)}
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

      when_ "the agent calls start_task for the release", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "release",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "approval is demanded through ask_user before anything deploys", context do
        assert context.prompt =~ "ask_user",
               "expected the approval to flow through ask_user (reaches the user's phone)"

        assert context.prompt =~ ~r/explicit (approval|yes)/i,
               "expected an explicit-approval contract"

        assert context.prompt =~ ~r/deploy nothing|nothing.*(before|without).*(yes|approval)/i,
               "expected a hard nothing-deploys-before-approval line"

        {:ok, context}
      end
    end
  end
end
