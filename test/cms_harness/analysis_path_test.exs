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
    on_exit(fn -> if previous, do: System.put_env("CMS_PROJECT_ID", previous) end)

    project = project_dir()
    on_exit(fn -> stop_project(project.id) end)

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

    source =
      if Keyword.get(opts, :broken, false) do
        "defmodule Demo.Thing do\n  def go do\n    unclosed(\n  end\nend\n"
      else
        "defmodule Demo.Thing do\n  def go, do: :ok\nend\n"
      end

    write(root, "lib/thing.ex", source)
    {_, 0} = System.cmd("mix", ["deps.get"], cd: root, stderr_to_stdout: true)
    :ok
  end

  defp await_connected(project_id, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if ChannelClient.connected?(project_id) do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
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
    if ctx.client_utils? do
      make_compilable(ctx.project.root, broken: true)

      FakeServer.start()
      {:ok, _} = Projects.ensure_started(ctx.project.root)
      assert await_connected(ctx.project.id)

      FakeServer.request_analysis([%{"run_id" => 7, "source" => "compiler", "args" => []}])

      payload = await_result(7)

      assert payload["source"] == "compiler"
      assert payload["status"] == "ok"

      assert [_ | _] = payload["result"]["diagnostics"],
             "the whole point: a working copy that does not compile produces diagnostics " <>
               "on the wire, where before this there was no wire and no diagnostics"

      assert Enum.any?(payload["result"]["diagnostics"], &(&1["severity"] == "error"))
    else
      IO.warn("no client_utils checkout at #{@client_utils}; the analyzer path is unchecked")
    end
  end

  test "a run for an analyzer that cannot run is answered, not dropped", ctx do
    FakeServer.start()
    {:ok, _} = Projects.ensure_started(ctx.project.root)
    assert await_connected(ctx.project.id)

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
    assert await_connected(ctx.project.id)

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

  test "a second run of a source already in flight is refused, and the refusal is sent", ctx do
    FakeServer.start()
    {:ok, _} = Projects.ensure_started(ctx.project.root)
    assert await_connected(ctx.project.id)

    # Both in one push, so the second is queued behind the first rather than
    # racing it. Two `mix test` processes in one `_build` corrupt it, which is
    # the reason the queue exists at all.
    FakeServer.request_analysis([
      %{"run_id" => 21, "source" => "sobelow", "args" => []},
      %{"run_id" => 22, "source" => "sobelow", "args" => []}
    ])

    assert %{"status" => "error", "error" => "already running"} = await_result(22)
    assert %{"status" => "error"} = await_result(21)

    assert AnalysisServer.idle?(ctx.project.id)
  end
end
