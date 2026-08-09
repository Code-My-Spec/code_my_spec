defmodule CodeMySpec.Analysis.FreshSourcesTest do
  @moduledoc """
  `fresh_sources/2` must answer exactly what `fresh?/2` answers, one source at a
  time — the only difference being that it loads the file ledger once instead of
  once per source.

  That equivalence is the whole claim, so it is what these assert. The cost
  motivating it: `Fingerprint.current/2` loads every file row for the working
  copy (4,544 on this project), and the stop hook asked once per source with
  problems, so a turn spent four or five full loads of one table to compute four
  hashes of it.

  The subtle part is which run each looks at. `status/1` reads
  `latest_full_runs/1` and treats a failed newest run as stale; `fresh?/2` skips
  failures to find the newest run that actually *answered*, because a duplicate
  enqueue refused as "already queued" must not unseat a good result. Building on
  `status/1` would have been the obvious shortcut and would have changed the
  answer.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Fingerprint
  alias CodeMySpec.Analysis.RunsRepository

  setup do
    %{scope: full_scope_fixture()}
  end

  defp start_run(scope, source, fingerprint) do
    {:ok, run} =
      RunsRepository.start_run(scope, %{
        source: source,
        kind: :full,
        args: %{"args" => []},
        input_fingerprint: fingerprint
      })

    run
  end

  defp agree?(scope, sources) do
    fresh = Analysis.fresh_sources(scope, sources)
    Enum.all?(sources, &(MapSet.member?(fresh, &1) == Analysis.fresh?(scope, &1)))
  end

  @sources ~w(compiler credo exunit spex)

  test "with no runs at all, nothing is fresh and both agree", %{scope: scope} do
    assert Analysis.fresh_sources(scope, @sources) == MapSet.new()
    assert agree?(scope, @sources)
  end

  test "a completed run at the current fingerprint is fresh", %{scope: scope} do
    current = Fingerprint.current(scope, "credo")

    scope
    |> start_run("credo", current)
    |> RunsRepository.finish_run(:completed, %{})

    assert MapSet.member?(Analysis.fresh_sources(scope, @sources), "credo")
    assert agree?(scope, @sources)
  end

  test "a completed run at a stale fingerprint is not fresh", %{scope: scope} do
    scope
    |> start_run("credo", "a-fingerprint-from-another-tree")
    |> RunsRepository.finish_run(:completed, %{})

    refute MapSet.member?(Analysis.fresh_sources(scope, @sources), "credo")
    assert agree?(scope, @sources)
  end

  # The distinction that rules out building this on `status/1`.
  test "a failed run does not unseat an older completed one", %{scope: scope} do
    current = Fingerprint.current(scope, "exunit")

    scope
    |> start_run("exunit", current)
    |> RunsRepository.finish_run(:completed, %{})

    scope
    |> start_run("exunit", current)
    |> RunsRepository.finish_run(:failed, %{})

    assert MapSet.member?(Analysis.fresh_sources(scope, @sources), "exunit"),
           "a refused duplicate must not make a good result stale"

    assert agree?(scope, @sources)
  end

  test "sources are answered independently", %{scope: scope} do
    scope
    |> start_run("credo", Fingerprint.current(scope, "credo"))
    |> RunsRepository.finish_run(:completed, %{})

    scope
    |> start_run("spex", "stale")
    |> RunsRepository.finish_run(:completed, %{})

    fresh = Analysis.fresh_sources(scope, @sources)

    assert MapSet.member?(fresh, "credo")
    refute MapSet.member?(fresh, "spex")
    assert agree?(scope, @sources)
  end

  test "an empty source list asks nothing", %{scope: scope} do
    assert Analysis.fresh_sources(scope, []) == MapSet.new()
  end
end
