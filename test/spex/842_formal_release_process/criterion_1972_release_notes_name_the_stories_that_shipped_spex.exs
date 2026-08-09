defmodule CodeMySpecSpex.Story842.Criterion1972Spex do
  @moduledoc """
  Story 842 — Formal release process
  Criterion 1972 — Release notes name the stories that shipped.

  Notes that say "various fixes" are not notes. The point of the ceremony is
  that someone reading the release can tell which work is in it, which means
  the stories have to be named rather than counted.

  Surface: HTTP `POST /api/agent-tasks/start`. The release task compiles its
  notes from the stories on UAT since the last release, so what it is working
  from has to name them.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @release_type "Elixir.CodeMySpec.AgentTasks.Release"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Release notes name the stories that shipped" do
    scenario "two stories rode to UAT since the last release" do
      given_ "two named stories have been deployed to UAT and not released", context do
        first =
          CodeMySpecSpex.Fixtures.story_fixture(context.scope, %{
            title: "Story 842 first shipped thing"
          })

        second =
          CodeMySpecSpex.Fixtures.story_fixture(context.scope, %{
            title: "Story 842 second shipped thing"
          })

        for story <- [first, second] do
          :ok =
            Environments.write_file(
              context.environment,
              ".code_my_spec/devops/deploys/story_#{story.id}.md",
              "# Deploy\n\nstory #{story.id} to uat — verified\n"
            )
        end

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      when_ "the agent starts the release", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/agent-tasks/start", %{"session_type" => @release_type})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :prompt, response["prompt"] || response["error"] || "")}
      end

      then_ "both stories are named", context do
        assert context.prompt =~ context.first.title,
               "expected the first shipped story to be named, got: #{context.prompt}"

        assert context.prompt =~ context.second.title,
               "expected the second shipped story to be named, got: #{context.prompt}"

        {:ok, context}
      end

      then_ "they are named rather than counted", context do
        refute context.prompt =~ ~r/2 stories\b(?!.*Story 842)/,
               "a count is not a name — the reader has to be able to tell what shipped"

        {:ok, context}
      end
    end
  end
end
