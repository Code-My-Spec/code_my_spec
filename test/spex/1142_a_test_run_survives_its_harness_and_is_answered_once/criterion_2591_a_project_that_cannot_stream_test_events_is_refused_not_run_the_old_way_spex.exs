defmodule CodeMySpecSpex.Story1142.Criterion2591Spex do
  @moduledoc """
  Story 1142 — A test run survives its harness and is answered once.
  Criterion 2591 — A project that cannot stream test events is refused, not
  run the old way.

  A project whose client_utils is older than 0.4.0 has no run session to
  link: its run is refused with what to install, and nothing of it runs.
  """

  # One harness tree and one machine-wide slot table per node.
  use CodeMySpecSpex.Case, async: false

  import CmsHarnessTest.Projects,
    only: [
      ensure_harness_supervisor_started: 0,
      project_dir: 0,
      stop_project: 1,
      ensure_started: 1,
      write: 3
    ]

  import CmsHarnessTest.AnalysisResults

  alias CmsHarnessTest.FakeServer

  # The refusal is logged at error by the harness, as every unanswerable run
  # is; that log is the outcome under test here, not a fault.
  spex "A project that cannot stream test events is refused, not run the old way",
    criterion: 2591,
    fail_on_error_logs: false do
    scenario "Sam's project has no client_utils that streams" do
      given_ "Sam's project has a suite but no client_utils 0.4.0", context do
        ensure_harness_supervisor_started()
        project = project_dir()
        ran = Path.join(project.root, "the_suite_ran")
        write(project.root, "mix.exs", mix_exs())
        write(project.root, "test/test_helper.exs", "ExUnit.start()\n")

        write(project.root, "test/ran_test.exs", """
        defmodule RanTest do
          use ExUnit.Case
          test "runs", do: File.write!(#{inspect(ran)}, "")
        end
        """)

        on_exit(fn -> stop_project(project.root) end)
        FakeServer.start()
        {:ok, _pid} = ensure_started(project.root)
        await_connected(project.root)

        {:ok, Map.merge(context, %{project: project, ran: ran})}
      end

      when_ "his suite is asked to run", context do
        FakeServer.request_analysis([%{"run_id" => 1, "source" => "exunit", "args" => []}])
        {:ok, Map.put(context, :result, await_result(1))}
      end

      then_ "it is refused, saying what to install", context do
        assert context.result["status"] == "error", inspect(context.result)
        assert context.result["error"] =~ "needs client_utils 0.4.0 or later"
        assert context.result["error"] =~ "mix deps.get"
        {:ok, context}
      end

      then_ "and nothing of it ran", context do
        refute await_file(context.ran, 20), "the suite ran the old way"
        {:ok, context}
      end
    end
  end

  defp mix_exs do
    """
    defmodule NoStream.MixProject do
      use Mix.Project
      def project, do: [app: :no_stream, version: "0.1.0", deps: []]
    end
    """
  end
end
