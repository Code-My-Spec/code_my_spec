defmodule CodeMySpecSpex.HarnessReports do
  @moduledoc """
  What a harness reports, for `CodeMySpecSpex.HarnessHooks` to drive and wait
  on: an analyzer's result rebuilt from a recording (`result/3`), and whether
  its scan reports a path at all (`scanned?/1`).

  Its own boundary because it uses the executors' parsers and the scanner's
  classifier, which the spex boundary does not otherwise reach.
  """

  use Boundary,
    top_level?: true,
    deps: [CmsHarness, CodeMySpec.BddSpecs, CodeMySpec.Compile, CodeMySpec.Files]

  alias CmsHarness.Analysis
  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.Compile
  alias CodeMySpec.Files.Scanner

  @doc """
  Whether a harness's scan reports `path` — the scanner classifies it. A path
  it does not is never in a manifest, so there is nothing to wait for.
  """
  @spec scanned?(String.t()) :: boolean()
  def scanned?(path), do: Scanner.classify(path) != nil

  @doc """
  What `CmsHarness.Analysis.run/4` answers for `source`, rebuilt from a
  recording of the tool's own output instead of running the tool: a
  `mix compile` diagnostics JSONL, a credo `--format json` document, an
  `ExUnit` JSON formatter report, or a `mix spex` JSONL. `nil` is a clean run.

  Parsed by the same functions the harness's executors parse with
  (`Compile.parse_jsonl/1`, `Spex.parse_jsonl/2`,
  `CmsHarness.Analysis.spex_failure/1`), into the shape the cloud's
  `Analysis.Runners.from_raw/2` reads. Exit statuses are derived from what was
  found, as the replay seams derive them: nothing was shelled out.
  """
  @spec result(String.t(), String.t(), String.t() | nil) :: map()
  def result(root, "compiler", recording) do
    diagnostics =
      if recording,
        do:
          recording
          |> File.read!()
          |> Compile.parse_jsonl()
          |> Compile.relativize_diagnostics(root),
        else: []

    %{
      "source" => "compiler",
      "exit_status" => found(diagnostics),
      "diagnostics" => Enum.map(diagnostics, &stringify/1),
      "diagnostics_available" => true,
      "output" => ""
    }
  end

  def result(_root, "credo", recording) do
    {issues, output} =
      if recording do
        raw = File.read!(recording)
        {Jason.decode!(raw)["issues"] || [], raw}
      else
        {[], ""}
      end

    %{
      "source" => "credo",
      "exit_status" => found(issues),
      "diagnostics" => issues,
      "output" => output
    }
  end

  def result(_root, "exunit", recording) do
    report =
      if recording,
        do: recording |> File.read!() |> Jason.decode!(),
        else: %{"failures" => [], "stats" => %{"tests" => 1, "failures" => 0}}

    failures = Enum.map(report["failures"] || [], &test_failure/1)

    %{
      "source" => "exunit",
      "exit_status" => found(failures),
      "execution_status" => if(failures == [], do: "success", else: "failure"),
      "output" => "",
      "stats" => report["stats"] || %{},
      "diagnostics" => failures
    }
  end

  def result(_root, "spex", recording) do
    {:ok, failures} = if recording, do: Spex.parse_jsonl(recording, nil), else: {:ok, []}

    %{
      "source" => "spex",
      "exit_status" => found(failures),
      "output" => "",
      "diagnostics" => Enum.map(failures, &Analysis.spex_failure/1)
    }
  end

  defp found([]), do: 0
  defp found(_findings), do: 1

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  # The ExUnit JSON formatter's failure, as `CmsHarness.Analysis` sends one.
  defp test_failure(%{"error" => %{} = error}),
    do: %{"file" => error["file"], "line" => error["line"], "message" => error["message"]}

  defp test_failure(failure),
    do: %{"file" => nil, "line" => nil, "message" => failure["fullTitle"] || failure["title"]}
end
