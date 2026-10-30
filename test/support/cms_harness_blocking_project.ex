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

  require Logger

  @doc """
  Write a blocking `compiler` analyzer into `root`. Returns the marker path
  `unblock/1` takes.
  """
  @spec make_blocking(String.t()) :: String.t()
  def make_blocking(root) do
    marker = Path.join(root, ".blocking_marker")
    started = Path.join(root, ".blocking_started")
    executions = Path.join(root, ".blocking_executions")
    armed = Path.join(root, ".blocking_armed")

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Mix.Tasks.Compile.Blocking do
      use Mix.Task.Compiler

      def run(_args) do
        if File.exists?(#{inspect(armed)}) do
          File.write!(#{inspect(started)}, "started")
          File.write!(#{inspect(executions)}, "x", [:append])
          wait_for_unblock(2_000)
        end

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

    # 55379e16: a cold `_build/analyzer` (Mix booting, the custom compiler
    # module, protocol consolidation, deps resolution) could itself take
    # longer than a scenario's own short `harness_analysis_timeout` under
    # load -- indistinguishable, from inside that budget, from the hang the
    # scenario means to create. Before this fixed it, 55379e16's own bug
    # masked it: a timed-out run's orphaned subprocess kept running after
    # the "kill", so the cold compile finished and wrote its marker anyway.
    # Now that a timeout really kills the process tree, the cold compile has
    # to fit inside the short budget on its own merit, which it cannot.
    #
    # Compiled here, unarmed (`run/1` above is a no-op without the marker),
    # with the default long timeout and no server dispatch involved at all --
    # same `MIX_BUILD_PATH`/`MIX_ENV` the real dispatched run will use, so
    # this is the exact cache that run reuses, not a separate one.
    env = [{"MIX_ENV", "test"}, {"MIX_BUILD_PATH", CmsHarness.AnalyzerEnv.build_path(root)}]
    warm_started_at = System.monotonic_time(:millisecond)

    {output, 0} =
      System.cmd("mix", ["compile", "--return-errors"],
        cd: root,
        env: env,
        stderr_to_stdout: true
      )

    boot_ms = System.monotonic_time(:millisecond) - warm_started_at
    File.write!(Path.join(root, ".blocking_boot_ms"), Integer.to_string(boot_ms))

    unless output == "" do
      Logger.debug("[CmsHarnessTest.BlockingProject] warm compile output: #{output}")
    end

    File.write!(armed, "armed")

    marker
  end

  @doc """
  How long `make_blocking/1`'s own unarmed warm compile took on this
  machine, right now, for this exact project (same `MIX_BUILD_PATH`, same
  `mix.exs`) -- the real per-invocation cost of spawning `mix` as a
  subprocess here, not a guessed constant. 55379e16: a fixed millisecond
  budget races this cost on a busier day; this reads it instead.
  """
  @spec warm_boot_ms(String.t()) :: non_neg_integer()
  def warm_boot_ms(root) do
    root |> Path.join(".blocking_boot_ms") |> File.read!() |> String.to_integer()
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

  The default waits up to 30s at a 10ms poll, under ExUnit's own 60s test
  timeout, so a genuine hang raises this fixture's clear "never started".
  """
  @spec await_started(String.t(), pos_integer()) :: :ok
  def await_started(root, attempts \\ default_attempts()) do
    started = Path.join(root, ".blocking_started")
    do_await_started(started, attempts)
  end

  defp default_attempts, do: 3_000

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
