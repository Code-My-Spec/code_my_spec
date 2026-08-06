defmodule CodeMySpecSpex.Story859.Criterion7318Spex do
  @moduledoc """
  Story 859 — Formal release process
  Criterion 7318 — The release is published in all three places.

  After approval, the release is an annotated git tag, a GitHub Release,
  and a repo record — all carrying the same agent-proposed semver version
  and the same notes.

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

  spex "The release is published in all three places" do
    scenario "the release prompt publishes tag, GitHub Release, and repo record" do
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

      then_ "the agent proposes a semver version", context do
        assert context.prompt =~ ~r/semver/i,
               "expected an agent-proposed semver version"

        assert context.prompt =~ ~r/major\/minor\/patch|major, minor/i,
               "expected the semver judgment to be spelled out"

        {:ok, context}
      end

      and_ "tag, GitHub Release, and repo record all carry the version and notes", context do
        assert context.prompt =~ ~r/annotated git tag/i
        assert context.prompt =~ ~r/GitHub Release/i
        assert context.prompt =~ ".code_my_spec/releases/"

        {:ok, context}
      end
    end
  end
end
