defmodule Mix.Tasks.Cms.Eval do
  @shortdoc "Run the behavioural agent evals"

  @moduledoc """
  Measure how agents behave with the prompt and tools they actually have.

      mix cms.eval                       # every behavioural criterion
      mix cms.eval --pattern criterion_3539
      mix cms.eval --runs 3              # fewer measurements, while writing one

  These are spex like any other, in `test/spex/1070_*`, and they are excluded
  from every ordinary run by `config :ex_unit, exclude: [:eval]`. This task is
  the switch: it includes the tag, raises the per-test deadline, and hands the
  rest to `mix spex`.

  ## Why they are not in the gate

  A criterion here starts a fresh agent, lets it take real turns against a real
  model, and repeats that ten times. Minutes each, and a dozen of them. The
  promote gate runs the spex suite under a deadline, so carrying these would
  make every promotion wait on a measurement — and a measurement that has to
  finish inside somebody else's deadline stops being one.

  Run them when a prompt, a role brief or a tool list changes. That is when the
  answer can have moved, and it is exactly the change nothing else here
  notices.

  ## Reading the result

  A failure reports a rate, not a pass or a fail. A rate in the middle is the
  finding: the agent read the instruction one way sometimes and another way
  the rest of the time, which is a statement about the prompt being ambiguous.
  Fix the ambiguity and measure again — re-running until it passes is
  discarding the measurement.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  alias Mix.Tasks.Spex

  @default_timeout 900_000

  @impl Mix.Task
  def run(args) do
    {runs, args} = take_flag(args, "--runs")
    {timeout, args} = take_flag(args, "--timeout")

    Application.put_env(:ex_unit, :include, [:eval])
    Application.put_env(:ex_unit, :exclude, [])

    if runs, do: Application.put_env(:code_my_spec, :agent_eval_runs, String.to_integer(runs))

    Spex.run(spex_args(args, timeout))
  end

  # Taken out by hand rather than through `OptionParser`, because everything
  # this does not recognise has to reach `mix spex` untouched — and `parse/2`
  # drops an unknown switch into `invalid` and carries on, so `--pattern` would
  # silently vanish and the whole suite would run instead of the one criterion
  # that was asked for.
  defp take_flag(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> {nil, args}
      i -> {Enum.at(args, i + 1), List.delete_at(List.delete_at(args, i), i)}
    end
  end

  # A behavioural run is many model calls, and ExUnit's deadline is per test
  # rather than per turn. Fifteen minutes because ten runs of a multi-turn
  # scenario genuinely take that, and a timeout part-way through discards every
  # run that had already completed.
  defp spex_args(args, timeout) do
    named_files? =
      Enum.any?(args, &(&1 == "--pattern")) or Enum.any?(args, &String.ends_with?(&1, "_spex.exs"))

    pattern = if named_files?, do: [], else: ["--pattern", default_pattern()]

    args ++ pattern ++ ["--timeout", timeout || to_string(@default_timeout)]
  end

  # Only story 1070's directory. Every other spex carries no `:eval` tag, so
  # including the tag would run them too — and this task exists to run the
  # expensive ones deliberately, not to run the whole suite with a long
  # deadline.
  defp default_pattern, do: "test/spex/1070_*/**/*_spex.exs"
end
