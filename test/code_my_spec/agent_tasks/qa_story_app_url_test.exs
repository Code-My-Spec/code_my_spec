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

  defp prompt_without_a_working_copy, do: prompt_with_app(nil)

  defp prompt_with_app(info) do
    tmp_dir = CodeMySpec.TempFile.owned_dir("qa_story_app_url")
    scope = working_copy_scope_fixture()
    scope = put_fixture_environment(scope, Environment.new(:local, tmp_dir))
    :ok = register_working_copy_environment(scope, Environment.new(:local, tmp_dir))
    story = story_fixture(scope)

    plan_path = Path.join(tmp_dir, ".code_my_spec/qa/plan.md")
    plan_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(plan_path, "# QA plan\n\nNothing to see.\n")

    scope = configure_app(scope, tmp_dir, info)

    {_, id, session} = CodeMySpecSpex.Fixtures.qa_story_task_fixture(scope, story: story)
    {:ok, prompt} = QaStory.command(scope, CodeMySpec.TaskOwner.find_task(session, id))

    prompt
  end

  # Keep the field present for the fallback's embedding and file paths.
  defp configure_app(scope, _tmp_dir, nil), do: %{scope | active_working_copy_id: nil}

  defp configure_app(scope, tmp_dir, info) do
    caller = self()

    pid =
      spawn_link(fn ->
        :ok =
          CodeMySpec.Analysis.HarnessRegistry.register_executor(
            scope.active_working_copy_id,
            "qa-revision-test",
            tmp_dir
          )

        send(caller, {:registered, self()})

        receive do
          {:"$gen_call", from, {:ensure_app_running, %{}}} ->
            GenServer.reply(from, {:ok, info})
        end
      end)

    assert_receive {:registered, ^pid}, 2_000
    scope
  end

  test "QA refuses a healthy app serving an older checkout revision" do
    prompt =
      prompt_with_app(%{
        status: "serving",
        url: "http://127.0.0.1:12345",
        commit: "old",
        serving_commit: "old",
        head: "new"
      })

    assert prompt =~ "App verification blocked"
    assert prompt =~ "Served revision: old"
    assert prompt =~ "checkout HEAD: new"
    refute prompt =~ "Test against this address"
    refute prompt =~ "http://127.0.0.1:12345"
  end

  test "QA uses the reloaded revision rather than the launch revision" do
    prompt =
      prompt_with_app(%{
        status: "serving",
        url: "http://127.0.0.1:12345",
        commit: "old",
        serving_commit: "new",
        head: "new"
      })

    assert prompt =~ "http://127.0.0.1:12345"
    assert prompt =~ "Test against this address"
    refute prompt =~ "App verification blocked"
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
