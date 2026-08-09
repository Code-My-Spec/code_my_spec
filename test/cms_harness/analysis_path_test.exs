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

  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects
  import ExUnit.CaptureLog

  alias CmsHarness.Project.{AnalysisServer, ChannelClient}
  alias CmsHarness.Projects
  alias CmsHarnessTest.FakeServer

  @moduletag timeout: 300_000

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
    {_, 0} = System.cmd("mix", ["deps.get"], cd: root, stderr_to_stdout: true)
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

  test "a second run of a source already queued is superseded, not failed", ctx do
    FakeServer.start()
    {:ok, _} = Projects.ensure_started(ctx.project.root)
    assert await_connected(ctx.project.root)

    # Both in one push, so the second lands while the first is still queued.
    # Two `mix test` processes in one `_build` corrupt it, which is the reason
    # the queue exists at all, and a second *pending* run for one source can
    # only ever deliver the same answer twice.
    FakeServer.request_analysis([
      %{"run_id" => 21, "source" => "sobelow", "args" => []},
      %{"run_id" => 22, "source" => "sobelow", "args" => []}
    ])

    # `superseded`, not `error`. The run never ran and nothing went wrong — the
    # queued one answers for both. Reported as a failure it made its source read
    # `failed` when nothing had failed, and could unseat a good result: 14 such
    # rows in half an hour on one harness.
    assert %{"status" => "superseded", "error" => "already queued"} = await_result(22)
    assert %{"status" => "error"} = await_result(21)

    assert AnalysisServer.idle?(ctx.project.root)
  end
end
