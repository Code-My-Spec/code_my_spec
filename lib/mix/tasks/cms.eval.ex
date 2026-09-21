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
  `Support.InMemoryEnvironment`, where `Environments.write_file/3` answers `:ok`
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

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
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
