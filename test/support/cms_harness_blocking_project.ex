defmodule CmsHarnessTest.BlockingProject do
  @moduledoc """
  A working copy whose "compiler" analyzer blocks until told to proceed.

  Story 839's criteria are about what happens while a run is genuinely in
  flight — a duplicate request arriving, a machine-wide slot being held. A
  real `mix compile` finishes in an unpredictable handful of milliseconds,
  which makes "arrives while running" a race against a timer rather than a
  fact a test can arrange. This makes it a fact instead: the compile step
  blocks on a marker file until a test says to proceed, so there is a real
  window — as long as the test needs — during which the run is provably
  still executing.

  Not a stub of the analyzer path. `CmsHarness.Analysis.run/3` still shells
  out to a real `mix compile` against a real project on disk; only the
  project's own compile step is written to wait, the same way a slow fixture
  would, just without the wall-clock variance.
  """

  import CmsHarnessTest.Projects, only: [write: 3]

  @doc """
  Write a blocking `compiler` analyzer into `root`. Returns the marker path
  `unblock/1` takes.
  """
  @spec make_blocking(String.t()) :: String.t()
  def make_blocking(root) do
    marker = Path.join(root, ".blocking_marker")
    started = Path.join(root, ".blocking_started")
    executions = Path.join(root, ".blocking_executions")

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Mix.Tasks.Compile.Blocking do
      use Mix.Task.Compiler

      def run(_args) do
        File.write!(#{inspect(started)}, "started")
        File.write!(#{inspect(executions)}, "x", [:append])
        wait_for_unblock(2_000)
        {:ok, []}
      end

      defp wait_for_unblock(0), do: :ok

      defp wait_for_unblock(remaining) do
        if File.exists?(#{inspect(marker)}) do
          :ok
        else
          Process.sleep(10)
          wait_for_unblock(remaining - 1)
        end
      end
    end

    defmodule Demo.MixProject do
      use Mix.Project

      def project do
        [
          app: :demo,
          version: "0.1.0",
          elixir: "~> 1.14",
          compilers: [:blocking] ++ Mix.compilers()
        ]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """)

    write(root, "lib/thing.ex", "defmodule Demo.Thing do\n  def go, do: :ok\nend\n")

    marker
  end

  @doc """
  How many times the blocking compiler has actually started running in
  `root` — one character appended per invocation, so the count is the
  content's length rather than a value a race could read half-written.

  Exists for criteria about *coalescing*: several requests tied to one
  scheduled run must cost one execution, not one per request, and a marker
  file that only ever proves "at least once" cannot tell that apart from a
  bug that runs it again for each tied request.
  """
  @spec execution_count(String.t()) :: non_neg_integer()
  def execution_count(root) do
    case File.read(Path.join(root, ".blocking_executions")) do
      {:ok, content} -> String.length(content)
      {:error, :enoent} -> 0
    end
  end

  @doc """
  Block the caller until the blocking compiler has actually started running
  — not merely dispatched. The distinction matters: a request can be queued
  or waiting for a machine-wide slot for a while before its analyzer ever
  executes, and a test asserting "while it is running" needs that to be true
  before it acts.

  28a71ba6: the default bound used to be a fixed 500 attempts (5s) — shorter
  than `CmsHarness.AnalysisSlots.wait_ceiling/0`, the actual upper bound the
  system itself enforces on how long a dispatched run may legitimately wait
  for a machine-wide slot. A run queued behind real contention is not "never
  started," and this fixture's own moduledoc already says so. The default
  now follows that ceiling (at the unchanged 10ms poll interval) up to a cap
  of 3,000 attempts (30s, six times the old budget) -- enough margin for the
  contention actually observed, without tying a test fixture's own wait to
  production's full 30-minute ceiling and losing this raise's own clear
  diagnostic to ExUnit's generic test timeout on a real hang. A healthy run
  writes the marker in a handful of milliseconds regardless, so this does
  not slow the common case.
  """
  @spec await_started(String.t(), pos_integer()) :: :ok
  def await_started(root, attempts \\ default_attempts()) do
    started = Path.join(root, ".blocking_started")
    do_await_started(started, attempts)
  end

  # Capped well under ExUnit's own 60s default test timeout: tying this
  # directly to `wait_ceiling/0` (30 minutes in production, with no test
  # override) let a genuine hang surface as ExUnit's own generic timeout
  # instead of this fixture's clear "never started" raise -- observed once
  # this bag, in a batch run. 30s is six times the old fixed budget (enough
  # margin for the contention actually observed) while leaving this
  # fixture's own diagnostic room to fire first.
  @max_attempts 3_000
  defp default_attempts, do: min(div(CmsHarness.AnalysisSlots.wait_ceiling(), 10), @max_attempts)

  defp do_await_started(_started, 0),
    do: raise("the blocking compiler never started — check the run was actually dispatched")

  defp do_await_started(started, attempts) do
    if File.exists?(started) do
      :ok
    else
      Process.sleep(10)
      do_await_started(started, attempts - 1)
    end
  end

  @doc "Let a blocked compile finish."
  @spec unblock(String.t()) :: :ok
  def unblock(marker), do: File.write!(marker, "go")
end
