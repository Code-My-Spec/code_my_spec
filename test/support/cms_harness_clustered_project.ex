defmodule CmsHarnessTest.ClusteredProject do
  @moduledoc """
  A working copy whose suite runs on the real `ClientUtils.TestFormatter` and
  holds its one test open until released, so a run is provably executing for
  as long as a scenario needs. The held test records the OS pid of the
  `mix test` running it, which is what "nothing of it keeps running" is
  checked against.

  Built on CodeMySpec's own `deps/` and lockfile, so nothing is fetched. The
  dependencies are compiled once per test run into a template build, and each
  copy starts from its own copy of that, so only the first scenario pays for
  the compile. Copied, not shared: the copy's own runs write into its build,
  and a run killed mid-write must not corrupt the next scenario's.
  """

  import CmsHarnessTest.Projects, only: [write: 3]

  @hold_ms 60_000
  @poll_ms 10

  @doc "Write the project into `root` and compile it where its analyzer builds."
  @spec make(String.t()) :: :ok
  def make(root) do
    write(root, "mix.exs", mix_exs())
    write(root, "test/test_helper.exs", "ExUnit.start()\n")
    write(root, "test/held_test.exs", held_test(pid_file(root), release_file(root)))
    seed_build(root)
    compile!(root)
  end

  defp compile!(root) do
    {output, status} =
      System.cmd("mix", ["compile"], cd: root, env: build_env(root), stderr_to_stdout: true)

    status == 0 || raise "the clustered project did not compile:\n#{output}"
    :ok
  end

  @doc """
  `make/1` with a suite to watch: a file whose test passes, a file whose test
  fails with `failure/0`, and the held file, all `async: true` so they run
  together and the held one keeps the run going while the others report.
  """
  @spec make_suite(String.t()) :: :ok
  def make_suite(root) do
    write(root, "test/passing_test.exs", passing_test())
    write(root, "test/failing_test.exs", failing_test())
    make(root)
  end

  @doc "What `make_suite/1`'s failing test reports: its message, file and line."
  @spec failure() :: %{message: String.t(), file: String.t(), line: pos_integer()}
  def failure,
    do: %{message: "the ledger did not balance", file: "test/failing_test.exs", line: 5}

  @doc "The held test's file, the one still running while the others have reported."
  @spec held_file() :: String.t()
  def held_file, do: "test/held_test.exs"

  @doc "End the run outright, as a crash would: the held `mix test` is killed."
  @spec kill(pos_integer()) :: :ok
  def kill(pid) do
    System.cmd("kill", ["-9", "#{pid}"], stderr_to_stdout: true)
    :ok
  end

  @doc """
  The OS pid of the `mix test` holding the test open, once the test is running.
  Raises if it never starts within `timeout_ms`.
  """
  @spec await_running(String.t(), pos_integer()) :: pos_integer()
  def await_running(root, timeout_ms \\ 30_000),
    do: await_pid(pid_file(root), div(timeout_ms, @poll_ms))

  @doc "Whether the OS process `pid` is still alive."
  @spec running?(pos_integer()) :: boolean()
  def running?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  @doc "Whether `pid` is gone within `timeout_ms`."
  @spec gone_within?(pos_integer(), pos_integer()) :: boolean()
  def gone_within?(pid, timeout_ms), do: gone?(pid, div(timeout_ms, @poll_ms))

  @doc """
  The harness as it runs on Windows: without `CodeMySpec.RunGuard`, which
  needs Unix process groups and does not start there. Restored on exit.
  """
  @spec as_on_windows() :: :ok
  def as_on_windows do
    _ = Supervisor.terminate_child(CmsHarness.Supervisor, CodeMySpec.RunGuard)

    ExUnit.Callbacks.on_exit(fn ->
      Supervisor.restart_child(CmsHarness.Supervisor, CodeMySpec.RunGuard)
    end)

    :ok
  end

  @doc "Let the held test finish."
  @spec release(String.t()) :: :ok
  def release(root), do: File.write!(release_file(root), "go")

  @doc """
  Run the suite as the harness would, naming a harness that is not there.
  Answers its exit status and whether any test ran.
  """
  @spec run_for_absent_harness(String.t()) :: %{exit: non_neg_integer(), ran?: boolean()}
  def run_for_absent_harness(root) do
    # Distributed from boot, as the harness starts a run; only the harness is missing.
    env =
      build_env(root) ++
        [
          {"ELIXIR_ERL_OPTIONS",
           "-name cms_run_absent_#{System.unique_integer([:positive])}@127.0.0.1 -setcookie qa"},
          {"CMS_HARNESS_NODE", "absent@127.0.0.1"},
          {"CMS_HARNESS_COOKIE", "qa"},
          {"CMS_RUN_ID", "1"}
        ]

    {_output, status} =
      System.cmd("mix", ["test", "--formatter", "ClientUtils.TestFormatter"],
        cd: root,
        env: env,
        stderr_to_stdout: true
      )

    %{exit: status, ran?: File.exists?(pid_file(root))}
  end

  defp pid_file(root), do: Path.join(root, ".run_pid")
  defp release_file(root), do: Path.join(root, ".release")

  defp build_env(root),
    do: [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", CmsHarness.AnalyzerEnv.build_path(root)}]

  # The copy's build starts as a copy of the template's.
  defp seed_build(root) do
    build = CmsHarness.AnalyzerEnv.build_path(root)
    File.mkdir_p!(Path.dirname(build))
    {:ok, _} = File.cp_r(template_build(), build)
    :ok
  end

  # Compiled once per BEAM, from scratch, in a project of its own.
  defp template_build do
    case :persistent_term.get({__MODULE__, :template}, nil) do
      nil ->
        root = CodeMySpec.TempFile.dir("clustered_project_template")
        File.mkdir_p!(root)
        write(root, "mix.exs", mix_exs())
        compile!(root)
        build = CmsHarness.AnalyzerEnv.build_path(root)
        :persistent_term.put({__MODULE__, :template}, build)
        build

      build ->
        build
    end
  end

  defp await_pid(_file, 0), do: raise("the held test never started — was the run dispatched?")

  defp await_pid(file, attempts) do
    case File.read(file) do
      {:ok, pid} when pid != "" ->
        String.to_integer(pid)

      _ ->
        Process.sleep(@poll_ms)
        await_pid(file, attempts - 1)
    end
  end

  defp gone?(_pid, 0), do: false

  defp gone?(pid, attempts) do
    if running?(pid) do
      Process.sleep(@poll_ms)
      gone?(pid, attempts - 1)
    else
      true
    end
  end

  defp mix_exs do
    """
    defmodule Demo.MixProject do
      use Mix.Project

      def project do
        [
          app: :demo,
          version: "0.1.0",
          elixir: "~> 1.14",
          deps_path: #{inspect(Mix.Project.deps_path())},
          lockfile: #{inspect(Path.expand("mix.lock"))},
          deps: [{:client_utils, path: #{inspect(Mix.Project.deps_paths()[:client_utils])}}]
        ]
      end
    end
    """
  end

  defp passing_test do
    """
    defmodule Demo.PassingTest do
      use ExUnit.Case, async: true

      test "adds up", do: assert(1 + 1 == 2)
    end
    """
  end

  # `failure/0` names this file and line 5, the assertion's.
  defp failing_test do
    """
    defmodule Demo.FailingTest do
      use ExUnit.Case, async: true

      test "balances the ledger" do
        flunk("#{failure().message}")
      end
    end
    """
  end

  defp held_test(pid_file, release_file) do
    """
    defmodule Demo.HeldTest do
      use ExUnit.Case, async: true

      @tag timeout: :infinity
      test "is held open until released" do
        File.write!(#{inspect(pid_file)}, System.pid())
        wait(#{div(@hold_ms, @poll_ms)})
      end

      defp wait(0), do: :ok

      defp wait(n) do
        if File.exists?(#{inspect(release_file)}), do: :ok, else: (Process.sleep(#{@poll_ms}); wait(n - 1))
      end
    end
    """
  end
end
