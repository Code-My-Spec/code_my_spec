defmodule CodeMySpecSpex.Story859.Criterion7317Spex do
  @moduledoc """
  Story 859 — Formal release process
  Criterion 7317 — Release notes name the stories that shipped.

  The release prompt compiles its manifest from the UAT deploy records
  since the last release and instructs user-facing notes built from the
  stories' titles and descriptions — not commit logs.

  Surface: `start_task` MCP tool against the project's `release`
  requirement, over a state with an unreleased UAT deploy.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Release notes name the stories that shipped" do
    scenario "the release prompt manifests the deployed stories by title" do
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

      then_ "the manifest names the deployed story", context do
        assert context.prompt =~ "story_#{context.story.id}",
               "expected the deployed story in the release manifest"

        assert context.prompt =~ context.story.title,
               "expected the story's title in the manifest; got: #{String.slice(context.prompt, 0, 500)}"

        {:ok, context}
      end

      and_ "the notes are compiled from the stories, not commit logs", context do
        assert context.prompt =~ ~r/release notes/i
        assert context.prompt =~ ~r/titles and descriptions/i
        refute context.prompt =~ ~r/from (the )?commit log/i

        {:ok, context}
      end
    end
  end
end
