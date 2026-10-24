defmodule Mix.Tasks.Cms.Eval do
  @shortdoc "Run the behavioural agent evals"

  @moduledoc """
  Measure how agents behave with the prompt and tools they actually have.

      mix cms.eval                       # every behavioural criterion
      mix cms.eval --pattern criterion_3539
      mix cms.eval --runs 3              # fewer measurements, while writing one

  Each run starts a fresh agent against a real model, records what it called,
  and writes an artifact under `test/fixtures/evals/`. `mix spex` then asserts
  on those artifacts and never calls a model.

  ## This is not a test run

  It used to be — this task set `include: [:eval]` and handed the rest to
  `mix spex`, so every eval inherited a spex's constraints. That is the
  coupling the artifact split exists to remove, and it cost a day:

  A spex runs inside ExUnit with the Ecto sandbox, and its environment is
  `Support.InMemoryExecutionContext`, where `ExecutionContexts.write_file/3` answers `:ok`
  and puts nothing on disk. Right for a scenario driving a LiveView, exactly
  wrong for one driving an agent — a real agent reads real files. The fixture
  and the agent were on two different filesystems, so the project chain never
  closed at the agent's vantage, one requirement was actionable in the whole
  world, and the first run consumed it. At n=10 the second run found nothing to
  do.

  `Support.EvalRunner` owns its setup instead: a real directory, real files, a
  disk-backed environment, no sandbox. Nothing about a measurement is bounded
  by what a spex can express.

  ## Reading the result

  A failure reports a rate, not a pass or a fail. A rate in the middle is the
  finding: the agent read the instruction one way sometimes and another way the
  rest of the time, which is a statement about the prompt being ambiguous. Fix
  the ambiguity and measure again — re-running until it passes is discarding the
  measurement.

  A run that errored is not in the denominator. It is not evidence about the
  agent, so it is recorded and taken again.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  # The pool flag has to be in the environment before `mix` boots, and nothing
  # arranged inside this file can put it there.
  #
  # Two attempts failed for the same reason while looking like different bugs.
  # `System.put_env("CMS_EVAL", "1")` at the module's top level runs when the
  # module is *compiled*, so the flag was set on whichever invocation happened
  # to recompile this file and on no other. Moving it into `run/1` and starting
  # the app by hand looked like the fix and was not: `config/test.exs` is
  # evaluated when the project is loaded, which is before any task runs at all.
  #
  # So every eval so far had run on `Ecto.Adapters.SQL.Sandbox`. That appears to
  # work — without `Sandbox.mode/2` the sandbox serves anybody — but it keeps
  # ownership semantics, and under those a process that runs one query owns that
  # connection until it *exits*. An agent turn is a long-lived process. Twenty
  # of them squat twenty connections, `pool_size` is `schedulers_online() * 2`,
  # and everything else starves until the 120-second `:ownership_timeout`
  # force-disconnects the squatters. That is the whole of why run 1 failed and
  # runs 2 and 3 of the same batch passed in 73 seconds on the recovered pool.
  # `DBConnection.ConnectionPool` has no such notion — a connection goes back
  # when the query ends.
  #
  # Re-executing is the only order that holds, so the task puts the flag in the
  # environment and runs itself again rather than asking to be invoked a
  # particular way and failing quietly when it is not.
  @impl Mix.Task
  def run(args) do
    if System.get_env("CMS_EVAL") in ~w(1 true) do
      Mix.Task.run("app.start")
      refuse_sandbox!()
      measure(args)
    else
      relaunch(args)
    end
  end

  defp relaunch(args) do
    {_, status} =
      System.cmd("mix", ["cms.eval" | args],
        env: [{"CMS_EVAL", "1"}, {"MIX_ENV", "test"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: exit({:shutdown, status})
  end

  # Loudly, because the sandbox does not refuse this caller. It serves it and
  # then starves it, and that surfaces minutes later as an agent reporting the
  # database is down — a measurement of the pool wearing an agent's words.
  defp refuse_sandbox! do
    pool = Application.get_env(:code_my_spec, CodeMySpec.Repo)[:pool]

    if pool == Ecto.Adapters.SQL.Sandbox do
      Mix.raise("""
      The Repo booted on #{inspect(pool)}, so this run would measure the pool
      rather than the agent. `CMS_EVAL=1` has to be in the environment before
      `mix` loads `config/test.exs`:

          CMS_EVAL=1 MIX_ENV=test mix cms.eval
      """)
    end
  end

  defp measure(args) do
    {runs, args} = take_flag(args, "--runs")
    {pattern, _args} = take_flag(args, "--pattern")

    opts =
      [pattern: pattern]
      |> then(fn o -> if runs, do: Keyword.put(o, :runs, String.to_integer(runs)), else: o end)
      |> Enum.reject(&match?({_, nil}, &1))

    # Resolved rather than aliased: the runner is test-only, and a compile-time
    # reference from `lib/` would break every other environment. Same shape as
    # `Mix.Tasks.Cms.TestFixtures` reaching `Support.TestAdapter`.
    runner = Module.concat([CodeMySpec, Support, EvalRunner])

    unless Code.ensure_loaded?(runner) do
      Mix.raise("""
      #{inspect(runner)} is not loaded. Evals run in the test environment,
      where `test/support` is compiled:

          MIX_ENV=test mix cms.eval
      """)
    end

    report = runner.run(opts)
    report_to_stdout(report)
  end

  defp report_to_stdout(%{criteria: criteria, artifact_root: root}) do
    Mix.shell().info("")

    Enum.each(criteria, fn %{criterion: id, behaviour: behaviour, outcomes: outcomes} ->
      measured = Enum.reject(outcomes, & &1.errored)
      hits = Enum.count(measured, & &1.held?)
      total = length(measured)
      errored = length(outcomes) - total

      rate = if total > 0, do: "#{hits}/#{total}", else: "no measured runs"
      note = if errored > 0, do: " (#{errored} errored, not counted)", else: ""

      Mix.shell().info("#{id}  #{rate}#{note}\n  #{behaviour}")
    end)

    Mix.shell().info("\nArtifacts in #{root}")
  end

  # Taken out by hand rather than through `OptionParser`: everything this does
  # not recognise has to reach the runner untouched, and `parse/2` drops an
  # unknown switch into `invalid` and carries on, so a flag would silently
  # vanish.
  defp take_flag(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> {nil, args}
      i -> {Enum.at(args, i + 1), List.delete_at(List.delete_at(args, i), i)}
    end
  end
end
