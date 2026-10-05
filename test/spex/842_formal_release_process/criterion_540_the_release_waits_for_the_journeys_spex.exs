defmodule CodeMySpecSpex.Story842.Criterion1971Spex do
  @moduledoc """
  Story 842 — Formal release process
  Criterion 1971 — The release waits for the journeys.

  A release cut before the user journeys are complete ships work nobody has
  walked through end to end. The rhythm the story asks for depends on that
  order holding: journeys first, then the release.

  Surface: `CodeMySpec.AgentTasks.StartAgentTask.run/2`, called directly through
  `Fixtures.start_agent_task/2`. The requirement graph used to hand the release
  out as a node and no longer does (d207ad38), so starting the task is now an
  explicit request — and a request made too early is exactly what this
  criterion is about refusing. This used to go over HTTP to LocalWeb's
  `POST /api/agent-tasks/start`; that route is gone with the retired CLI
  (issue f532f990), and the criterion never promised the endpoint, only the
  refusal.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @release_type "release"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "The release waits for the journeys", criterion: 540 do
    scenario "UAT holds unreleased work, and the journeys are not done" do
      given_ "a story has been deployed to UAT and never released", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/devops/deploys/story_9001.md",
            "# Deploy\n\nstory 9001 to uat — verified\n"
          )

        {:ok, context}
      end

      when_ "the agent asks to start the release", context do
        response =
          Fixtures.start_agent_task(context.scope, %{
            "session_type" => @release_type,
            "external_id" => "spex-#{System.unique_integer([:positive])}"
          })

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it does not hand out a release", context do
        prompt = context.response["prompt"] || ""

        refute prompt =~ "tag",
               "expected no release to be cut while the journeys are outstanding, got: #{prompt}"

        {:ok, context}
      end

      then_ "it says the journeys come first", context do
        body = context.response["prompt"] || context.response["error"] || ""

        assert body =~ ~r/journey/i,
               "expected the refusal to name the journeys as what is outstanding, got: #{body}"

        {:ok, context}
      end
    end
  end
end
