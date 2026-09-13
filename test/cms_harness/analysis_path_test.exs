defmodule CmsHarness.AnalysisPathTest do
  @moduledoc """
  The analyzer path over a real websocket: the server asks, the harness runs
  `mix` against its working copy, and the result comes back.

  Same shape as `sync_path_test.exs` and for the same reason — an in-process
  test cannot see a wire. This one has an actual socket, an actual Slipstream
  client and an actual subprocess, so a payload that will not encode, a reply
  nobody reads, or a queue that answers nothing all show up here rather than in
  a drill.
  """

  # Sync: sets OS environment variables, which belong to the node rather than to
  # a test process, so the window is visible to everything running alongside.
  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects
  import ExUnit.CaptureLog

  alias CmsHarness.Project.{AnalysisServer, ChannelClient}
  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer

  @moduletag timeout: 300_000

  # On demand, not on every `mix test` — the twin of `analysis_test.exs`, which
  # was tagged for the same reason and this one was missed.
  #
  # It compiles a real project through the real harness path, against the
  # sibling `client_utils` checkout. That checkout's `_build` is shared by every
  # process that compiles against it, and nothing partitions it — so two suites
  # running at once contend there, and the compiler comes back `"error"` for
  # reasons that have nothing to do with the code under test.
  #
  # Not a hypothesis. Reproduced for `c8264c1f`: two full suites started
  # together on this commit, one clean and one failing here on
  # `payload["status"] == "ok"` getting `"error"`. That is the exact shape that
  # issue reports — an assertion, not a kill, in a test that exercises the
  # machinery running it — and it is why "passes standalone" was never evidence
  # of anything.
  @moduletag :analyzer

  @client_utils System.get_env("CMS_CLIENT_UTILS") ||
                  Path.expand("../client_utils", File.cwd!())

  setup do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")
    on_exit(fn -> restore_project_id(previous) end)

    project = project_dir()
    on_exit(fn -> stop_project(project.root) end)

    %{project: project, client_utils?: File.exists?(Path.join(@client_utils, "mix.exs"))}
  end

  # A working copy the compiler can actually be pointed at, written into the
  # directory the harness is already serving.
  defp make_compilable(root, opts) do
    File.write!(Path.join(root, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project

      def project do
        [
          app: :demo,
          version: "0.1.0",
          elixir: "~> 1.14",
          compilers: [:diagnostics] ++ Mix.compilers(),
          deps: [{:client_utils, path: #{inspect(@client_utils)}}]
        ]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """)

    write(root, "lib/thing.ex", thing_source(Keyword.get(opts, :broken, false)))
    cmd!(root, "mix", ["deps.get"])
    :ok
  end

  # A var that was unset before the test must stay unset after it, not become
  # the empty string.
  defp restore_project_id(nil), do: :ok
  defp restore_project_id(previous), do: System.put_env("CMS_PROJECT_ID", previous)

  defp thing_source(true), do: "defmodule Demo.Thing do\n  def go do\n    unclosed(\n  end\nend\n"
  defp thing_source(false), do: "defmodule Demo.Thing do\n  def go, do: :ok\nend\n"

  defp connected_step(true), do: {:halt, true}

  defp connected_step(false) do
    Process.sleep(50)
    {:cont, false}
  end

  defp await_connected(root, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      connected_step(ChannelClient.connected?(root))
    end)
  end

  # Drains until the result for `run_id` arrives, so an unrelated one cannot be
  # mistaken for the answer.
  defp await_result(run_id, timeout \\ 60_000) do
    receive do
      {:analysis_result, _project_id, %{"run_id" => ^run_id} = payload} -> payload
      {:analysis_result, _project_id, _other} -> await_result(run_id, timeout)
    after
      timeout -> flunk("no analysis_result for run #{run_id} within #{timeout}ms")
    end
  end

  test "the server asks, the harness runs the compiler, and the diagnostics come back", ctx do
    assert_compiler_diagnostics(ctx.client_utils?, ctx)
  end

  # Needs a sibling client_utils checkout to build against. Warns rather than
  # fails when there isn't one, so the suite still runs on a machine that has
  # not cloned it — but says so, because a silently skipped test and a passing
  # one are the same colour.
  defp assert_compiler_diagnostics(false, _ctx) do
    IO.warn("no client_utils checkout at #{@client_utils}; the analyzer path is unchecked")
  end

  defp assert_compiler_diagnostics(true, ctx) do
    make_compilable(ctx.project.root, broken: true)

    FakeServer.start()
    {:ok, _} = Projects.ensure_started(ctx.project.root)
    assert await_connected(ctx.project.root)

    FakeServer.request_analysis([%{"run_id" => 7, "source" => "compiler", "args" => []}])

    payload = await_result(7)

    assert payload["source"] == "compiler"
    assert payload["status"] == "ok"

    assert [_ | _] = payload["result"]["diagnostics"],
           "the whole point: a working copy that does not compile produces diagnostics " <>
             "on the wire, where before this there was no wire and no diagnostics"

    assert Enum.any?(payload["result"]["diagnostics"], &(&1["severity"] == "error"))
  end

  test "a run for an analyzer that cannot run is answered, not dropped", ctx do
    FakeServer.start()
    {:ok, _} = Projects.ensure_started(ctx.project.root)
    assert await_connected(ctx.project.root)

    # There is no mix project in this directory at all, so credo cannot run.
    FakeServer.request_analysis([%{"run_id" => 11, "source" => "sobelow", "args" => []}])

    payload = await_result(11)

    assert payload["status"] == "error",
           "a run the server opened and nobody answers sits `:running` forever, and " <>
             "every later stop then reports analysis pending — an allow, with a note " <>
             "that results apply next time, on a next time that never comes"

    assert payload["error"] =~ "unknown analyzer source"
  end

  test "a result the server rejects is reported loudly, not swallowed", ctx do
    FakeServer.start()
    FakeServer.reject_analysis("unknown_run")
    {:ok, _} = Projects.ensure_started(ctx.project.root)
    assert await_connected(ctx.project.root)

    log =
      capture_log(fn ->
        FakeServer.request_analysis([%{"run_id" => 13, "source" => "sobelow", "args" => []}])
        await_result(13)
        Process.sleep(500)
      end)

    assert log =~ "REJECTED",
           "an analyzer that ran and was not recorded looks from outside exactly like " <>
             "one that never ran"
  end

  # The reply above and this one arrive through the same path and are not the
  # same event. A supersede is a scheduling fact: the server had a run for this
  # source already open and it answers for both.
  #
  # `Reconciler.supersede/2` made this call on the server side — "at `:info`,
  # not `:warning` — nothing is wrong … logging it as a failure taught readers
  # to ignore a level that should mean something" — and the harness kept
  # shouting. 80 of the 385 rejections in this machine's `harness.log` were
  # supersedes, each at `level=error` under a message claiming the work was lost
  # and the next stop would report pending. Neither is true of a supersede, and
  # a log where `error` is routinely a non-event is one nobody reads.
  test "a supersede from the server is reported as a fact, not as a rejection", ctx do
    # The suite runs at `warning`, and the whole point of this change is that the
    # line is no longer above that. Lowered for the duration, restored by
    # `on_exit` rather than `try/after` — control flow is not allowed in a test
    # file, which is the rule this project's own credo check enforces.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    FakeServer.start()
    FakeServer.reject_analysis(~s({:superseded, "already queued"}))
    {:ok, _} = Projects.ensure_started(ctx.project.root)
    assert await_connected(ctx.project.root)

    log =
      capture_log(fn ->
        FakeServer.request_analysis([%{"run_id" => 31, "source" => "sobelow", "args" => []}])
        await_result(31)
        Process.sleep(500)
      end)

    refute log =~ "REJECTED",
           "a supersede is not a rejection, and calling it one trains readers to " <>
             "skip the level that should mean something"

    assert log =~ "superseded",
           "it should still say what happened — the analyzer did run, and that work " <>
             "was duplicated and discarded"
  end

  # Superseded twice over now (story 839, criterion 3439). This test used to
  # assert the run's answer that "superseded" run_id 22 got a synthetic status
  # carrying no data — the queued run answered for it, but "answered" meant
  # nothing about what actually happened to *its* request. Now it is tied, not
  # superseded: run_id 22 gets the exact same real result run_id 21 does,
  # because one execution genuinely answers for both.
  test "a second run of a source already queued is tied to it, not answered with an empty status",
       ctx do
    FakeServer.start()
    {:ok, _} = Projects.ensure_started(ctx.project.root)
    assert await_connected(ctx.project.root)

    # Both in one push, so the second lands while the first is still queued.
    # Two `mix test` processes in one `_build` corrupt it, which is the reason
    # the queue exists at all, and a second *pending* run for one source would
    # only ever deliver the same answer twice — so it is tied to the one
    # execution that will, rather than superseded with nothing.
    FakeServer.request_analysis([
      %{"run_id" => 21, "source" => "sobelow", "args" => []},
      %{"run_id" => 22, "source" => "sobelow", "args" => []}
    ])

    result_21 = await_result(21)
    result_22 = await_result(22)

    assert %{"status" => "error", "error" => error} = result_21
    assert error =~ "unknown analyzer source"

    assert %{"status" => "error", "error" => ^error} = result_22,
           "the tied request should get sobelow's real answer, not a synthetic " <>
             "'superseded' status carrying no data. Got: #{inspect(result_22)}"

    assert AnalysisServer.idle?(ctx.project.root)
  end
end
