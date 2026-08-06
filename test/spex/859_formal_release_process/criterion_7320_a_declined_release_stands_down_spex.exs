defmodule CodeMySpecSpex.Story859.Criterion7320Spex do
  @moduledoc """
  Story 859 — Formal release process
  Criterion 7320 — A declined release stands down.

  When the user declines the proposed release: nothing deploys, nothing
  is tagged, and the release requirement stays open for a later cycle.
  The prompt carries that stand-down contract.

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

  spex "A declined release stands down" do
    scenario "the release prompt carries the decline contract" do
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

      then_ "a decline means no deploy, no tag, and the release stays open", context do
        assert context.prompt =~ ~r/declines?/i,
               "expected the decline path to be spelled out"

        assert context.prompt =~ ~r/stand[s]? down/i,
               "expected an explicit stand-down instruction"

        assert context.prompt =~ ~r/no deploy, no tag/i,
               "expected the no-deploy-no-tag contract on decline"

        assert context.prompt =~ ~r/stays open|later cycle/i,
               "expected the release to remain open for a later cycle"

        {:ok, context}
      end
    end
  end
end
