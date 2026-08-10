defmodule CodeMySpecSpex.Story842.Criterion1976Spex do
  @moduledoc """
  Story 842 — Formal release process
  Criterion 1976 — A fresh UAT deploy reopens the release.

  This is what gives shipping a rhythm rather than a backlog. A release is not
  done once and forever: the moment new work reaches UAT, the cycle is open
  again and the tool should be asking for the next release. Without it, work
  accumulates on UAT and someone has to remember to ship it.

  Surface: HTTP `POST /api/agent-tasks/start`. Recurrence is content-based —
  satisfied only while every UAT deploy record's story is covered by some
  release record's `## Stories` manifest — so a deploy that no release covers
  should make the release askable again.

  ## Expected to fail, and this one is a decision rather than a bug

  `release` was removed from the requirement graph in d207ad38 along with
  `deploy` and `devops_setup`, because all three gated on markdown the agent
  wrote for itself. Reopening was a property of that requirement recurring, so
  with the node gone nothing reopens.

  The issue that asked for these spex back names this criterion specifically as
  "the behaviour to preserve or explicitly retire either way". Encoded as it
  reads, so the choice stays visible: either recurrence returns on a surface
  that observes real deploys, or the criterion is retired on purpose. A spec
  written to match today's behaviour would have quietly made that decision by
  omission.

  Its sibling is story 841's criterion 1963, which is red for the same reason
  from the other end of the same flow.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @release_type "release"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A fresh UAT deploy reopens the release" do
    scenario "everything shipped, then new work lands on UAT" do
      given_ "the user journeys have been walked", context do
        # The release refuses until a journey result exists.
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/qa/journey_result.md",
            "# Journey result\n\nwalked end to end — passed\n"
          )

        {:ok, context}
      end

      given_ "every story on UAT is covered by a release that already shipped", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/devops/deploys/story_9005.md",
            "# Deploy\n\nstory 9005 to uat — verified\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/releases/v1.0.0.md",
            # `story_<id>`, the format the release prompt specifies and
            # `released?/2` matches on a word boundary. Written with a space it
            # covers nothing, so the story reads unreleased and ships twice —
            # which is the failure this criterion is meant to catch, not stage.
            "# v1.0.0\n\n## Stories\n\n- story_9005\n"
          )

        {:ok, context}
      end

      given_ "a new story is then deployed to UAT", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/devops/deploys/story_9006.md",
            "# Deploy\n\nstory 9006 to uat — verified\n"
          )

        {:ok, context}
      end

      when_ "the agent asks what release work is outstanding", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/agent-tasks/start", %{
            "session_type" => @release_type,
            "external_id" => "spex-#{System.unique_integer([:positive])}"
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :prompt, response["prompt"] || response["error"] || "")}
      end

      then_ "a release is asked for again", context do
        assert context.prompt =~ ~r/release/i,
               "expected the new UAT deploy to reopen the release, got: #{context.prompt}"

        {:ok, context}
      end

      then_ "it is the uncovered story that reopened it", context do
        assert context.prompt =~ "9006",
               "expected the release to be reopened by the story no release covers, got: #{context.prompt}"

        refute context.prompt =~ "9005",
               "expected an already-shipped story to stay shipped rather than being released twice"

        {:ok, context}
      end
    end
  end
end
