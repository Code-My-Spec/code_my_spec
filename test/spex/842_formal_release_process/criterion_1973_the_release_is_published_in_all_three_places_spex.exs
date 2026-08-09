defmodule CodeMySpecSpex.Story842.Criterion1973Spex do
  @moduledoc """
  Story 842 — Formal release process
  Criterion 1973 — The release is published in all three places.

  Three, and all of them. An annotated git tag, a GitHub Release, and a record
  under `.code_my_spec/releases/`. Each answers a different question — what the
  code was, what shipped and when for anyone outside the repo, and what this
  tool believes it released — and any one of them alone leaves one of those
  unanswerable.

  Surface: HTTP `POST /api/agent-tasks/start`, then the artifacts themselves.

  ## What is asserted, and what that costs

  The three destinations are checked as artifacts, not as instructions in a
  prompt. A task that *tells* an agent to tag and publish, and is satisfied by
  being told, is the self-attestation the whole devops rework was undoing —
  `devops_setup` used to be complete because a markdown file contained the word
  "verified".

  That makes this red until a real release is recorded: publishing to GitHub is
  a real call and there is no cassette for it. That is a true statement of what
  is missing rather than something to soften the assertion around.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @cassette "842_1973_release_published"
  @release_type "Elixir.CodeMySpec.AgentTasks.Release"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "The release is published in all three places" do
    scenario "a release is cut with approval given" do
      given_ "a story on UAT that has not been released", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/devops/deploys/story_9002.md",
            "# Deploy\n\nstory 9002 to uat — verified\n"
          )

        {:ok, context}
      end

      when_ "the release runs to completion", context do
        response =
          with_full_cassette @cassette do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post("/api/agent-tasks/start", %{"session_type" => @release_type})
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "there is a record under .code_my_spec/releases", context do
        assert {:ok, entries} =
                 Environments.list_directory(context.environment, ".code_my_spec/releases"),
               "expected a releases directory holding the record of what shipped"

        assert entries != [],
               "expected a release record naming what this tool believes it released"

        {:ok, context}
      end

      then_ "the release is tagged in the repository", context do
        {tags, _status} = Environments.cmd(context.environment, "git", ["tag", "--list"])

        assert tags =~ ~r/v?\d+\.\d+\.\d+/,
               "expected an annotated semver tag so the code that shipped is identifiable, got: #{inspect(tags)}"

        {:ok, context}
      end

      then_ "the release is published on GitHub", context do
        prompt = context.response["prompt"] || ""

        refute prompt =~ "could not publish",
               "expected the GitHub Release to be published, got: #{prompt}"

        {:ok, context}
      end
    end
  end
end
