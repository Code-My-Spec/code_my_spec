defmodule CodeMySpec.AnalysisFixtures do
  @moduledoc """
  Fixtures for the analysis run ledger.

  A requirement reads the latest completed full run on the working copy,
  however old (28d72f8a). Which commit a run answers for is
  `start_commit`/`completed_commit`, which the promote gate reads.
  """

  alias CodeMySpec.Analysis.{Run, RunsRepository}

  @doc """
  Insert a completed full run per source — the run that answers for each.

  `commit:` also records the git state a harness reports: started on a clean
  tree at that commit and finished there, which is what the promote gate
  reads (`Run.at_commit?/2`). `start_tree_dirty:` and `completed_commit:`
  override either half.
  """
  def fresh_analysis_runs_fixture(scope, sources \\ Run.sources(), opts \\ []) do
    for source <- sources do
      {:ok, run} =
        RunsRepository.start_run(scope, %{source: source, kind: :full, args: gate_args(source)})

      {:ok, run} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})
      at_commit(run, Keyword.get(opts, :commit), opts)
    end
  end

  # As the promotion gate starts them: its compiler run is forced.
  defp gate_args("compiler"), do: %{"args" => ["--force"]}
  defp gate_args(_source), do: %{"args" => []}

  defp at_commit(run, nil, _opts), do: run

  defp at_commit(run, commit, opts) do
    RunsRepository.record_tree(run, %{
      start_commit: commit,
      start_tree_dirty: Keyword.get(opts, :start_tree_dirty, false),
      completed_commit: Keyword.get(opts, :completed_commit, commit)
    })
  end

  @doc "Insert a run in a given state."
  def analysis_run_fixture(scope, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{source: "exunit", kind: :full},
        attrs
      )

    {:ok, run} = RunsRepository.start_run(scope, attrs)

    case Map.get(attrs, :status_override) do
      nil ->
        run

      status ->
        {:ok, run} = RunsRepository.finish_run(run, status, %{})
        run
    end
  end
end
