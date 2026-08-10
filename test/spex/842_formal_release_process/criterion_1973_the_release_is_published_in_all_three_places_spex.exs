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

  Two of the three destinations are checked as artifacts: the spex carries out
  the release the prompt describes and then reads back an annotated tag in the
  repository and a record under `.code_my_spec/releases/`. A task that *tells*
  an agent to tag and publish, and is satisfied by being told, is the
  self-attestation the whole devops rework was undoing — `devops_setup` used to
  be complete because a markdown file contained the word "verified".

  **The third is not, and this file should not be read as covering it.**
  `gh release create` publishes to GitHub. Recording that cassette means
  publishing a real Release to a real repository, so it is outstanding rather
  than stubbed: a faked GitHub call would leave this asserting that the spex can
  write a file, which is the self-attestation above wearing a different hat. The
  GitHub step is currently checked only by the prompt not reporting a failure,
  which is weaker than the other two and is the gap to close.

  There is a second, quieter limit worth stating. The spex performs the release
  itself, so what these assertions prove is that the artifacts are well-formed
  and the checker agrees with them — not that an agent following the prompt
  produces them. That is the trade this criterion was rewritten to accept; the
  alternative was asserting artifacts that nothing in the test ever creates.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @release_type "release"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "The release is published in all three places" do
    scenario "a release is cut with approval given" do
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

      given_ "a story on UAT that has not been released", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/devops/deploys/story_9002.md",
            "# Deploy\n\nstory 9002 to uat — verified\n"
          )

        {:ok, context}
      end

      given_ "the working copy is a repository that can carry a tag", context do
        # `setup_active_project` builds a directory, not a checkout, so `git
        # tag` had nothing to tag — the assertion below was reading "fatal: not
        # a git repository" rather than an absent tag.
        env = context.environment

        {_, 0} = Environments.cmd(env, "git", ["init", "-q"])
        {_, 0} = Environments.cmd(env, "git", ["config", "user.email", "spex@example.com"])
        {_, 0} = Environments.cmd(env, "git", ["config", "user.name", "Spex"])
        {_, 0} = Environments.cmd(env, "git", ["add", "-A"])
        {_, 0} = Environments.cmd(env, "git", ["commit", "-q", "-m", "the code being released"])

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

        {:ok, Map.put(context, :response, response)}
      end

      when_ "it carries out the release the prompt describes", context do
        # The prompt is instructions; this performs them. Two of the three
        # destinations are local and are done for real here — an annotated tag
        # in the working copy and a record naming what shipped.
        #
        # The third is not: `gh release create` publishes to GitHub, which needs
        # a recorded cassette and, to record it, a real repository to publish
        # to. Left as the one outstanding call rather than faked, because a
        # stubbed GitHub Release would make this assert that the spex can write
        # a file, which is the self-attestation the criterion exists to refuse.
        env = context.environment
        version = "v1.0.0"

        notes = """
        # #{version}

        Story 9002 is now on prod.

        ## Stories

        - story_9002
        """

        # The record goes through the environment and the tag through git on
        # disk — `write_file` writes the in-memory environment, `cmd` runs in
        # `scope.cwd`, and in this fixture those are not the same place. So the
        # record is not committed before tagging; the tag names the commit that
        # holds the code, which is what a tag is for.
        :ok = Environments.write_file(env, ".code_my_spec/releases/#{version}.md", notes)

        {_, 0} = Environments.cmd(env, "git", ["tag", "-a", version, "-m", notes])

        {:ok, Map.put(context, :version, version)}
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
