defmodule CodeMySpec.AgentTasks.QaStoryAppUrlTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaStory
  alias CodeMySpec.Environments.Environment

  # ab4e412c
  #
  # The QA prompt's fallback "App URL" line told the agent to run
  # `mix run -e 'IO.puts(CodeMySpecWeb.Endpoint.url())'`. On any copy where the
  # app is already running — which is every copy QA runs against — that boots a
  # fresh BEAM that blocks on the compile lock the running release holds, rather
  # than failing fast: the reporter ran it twice and both attempts hung, 10s then
  # 60s, costing ~70s of a QA session for information the plan already documents.
  #
  # The rule it breaks is general and already paid for repeatedly here: never run
  # `mix` against a live server on this machine (:4000, :4003 and :4004 hold
  # compile locks). So the prompt must not teach that command shape at all.
  #
  # The fallback branch is reached when there is no working copy id to resolve —
  # either the scope names none, or the id it names does not exist. Both are real
  # states, and the first is the one exercised here.

  defp prompt_without_a_working_copy do
    tmp_dir = CodeMySpec.TempFile.owned_dir("qa_story_app_url")
    scope = working_copy_scope_fixture()
    scope = put_fixture_environment(scope, Environment.new(:local, tmp_dir))
    :ok = register_working_copy_environment(scope, Environment.new(:local, tmp_dir))
    story = story_fixture(scope)

    plan_path = Path.join(tmp_dir, ".code_my_spec/qa/plan.md")
    plan_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(plan_path, "# QA plan\n\nNothing to see.\n")

    # No active working copy on the scope: the fallback branch, and the only
    # state that renders main's app URL. `nil` and not a deleted key — the
    # embedding and file paths read this field and need it present.
    scope = %{scope | active_working_copy_id: nil}

    {:ok, prompt} =
      QaStory.command(scope, %{
        project_id: scope.active_project.id,
        component_id: nil,
        story_id: story.id
      })

    prompt
  end

  test "the App URL line does not tell the agent to boot a BEAM" do
    prompt = prompt_without_a_working_copy()

    refute prompt =~ "mix run -e",
           "the QA prompt teaches a `mix run` command that hangs against a live server"

    # Naming the module to say "don't boot it" is fine; instructing the reader to
    # run it is not. So the assertion is on the command, not the module name.
    refute prompt =~ "IO.puts",
           "printing a URL boots a BEAM, which blocks on the running release's compile lock"
  end

  test "the App URL line names the documented ports instead" do
    prompt = prompt_without_a_working_copy()

    assert prompt =~ "127.0.0.1:4000",
           "the hosted app's documented port should be named"

    assert prompt =~ "4004",
           "the local app's documented port should be named"
  end
end
