defmodule CodeMySpec.AnalysisFixtures do
  @moduledoc """
  Fixtures for the analysis run ledger.

  `tests_passing` / `spex_passing` requirements only count zero persisted
  problems as "passing" when the source's latest completed full run matches
  the current input fingerprint. Tests that set up files + zero problems and
  expect satisfaction must stamp fresh runs after their file setup — call
  `fresh_analysis_runs_fixture/2` AFTER the last file insert, since any later
  file change makes the fingerprint stale again (by design).
  """

  alias CodeMySpec.Analysis.{Fingerprint, Run, RunsRepository}

  @doc """
  Insert a completed full run per source at the CURRENT input fingerprint,
  marking every source's persisted problems as current.

  `commit:` also records the git state a harness reports: started on a clean
  tree at that commit and finished there, which is what the promote gate
  reads (`Run.at_commit?/2`). `start_tree_dirty:` and `completed_commit:`
  override either half.
  """
  def fresh_analysis_runs_fixture(scope, sources \\ Run.sources(), opts \\ []) do
    fingerprints = Fingerprint.current(scope)

    for source <- sources do
      {:ok, run} =
        RunsRepository.start_run(scope, %{
          source: source,
          kind: :full,
          input_fingerprint: fingerprints[source]
        })

      {:ok, run} = RunsRepository.finish_run(run, :completed, %{exit_status: 0})
      at_commit(run, Keyword.get(opts, :commit), opts)
    end
  end

  defp at_commit(run, nil, _opts), do: run

  defp at_commit(run, commit, opts) do
    RunsRepository.record_tree(run, %{
      start_commit: commit,
      start_tree_dirty: Keyword.get(opts, :start_tree_dirty, false),
      completed_commit: Keyword.get(opts, :completed_commit, commit)
    })
  end

  @doc "Insert a run in a given state without touching fingerprint currency."
  def analysis_run_fixture(scope, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{source: "exunit", kind: :full, input_fingerprint: "stale-fingerprint"},
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
