defmodule CodeMySpec.AnalyzerDomainTest do
  @moduledoc """
  Every enumeration of the analyzer sources agrees with the canonical one.

  ## The shape

  Six modules, across two apps, each hardcode `~w(compiler credo exunit spex)`.
  They agree today by luck: nothing links them, so adding a fifth analyzer means
  finding all six, and finding five of six is a bug that compiles.

  This session produced seven instances of that shape, two of them in exactly
  this domain — `Pipeline.@role_analyzers` against `Fingerprint.@source_roles`
  (`ad53f4ed`: a test edit made exunit stale and scheduled everything except
  exunit, so no correct action could clear the finding), and
  `@configurable_sources` against `Run.@sources`. Both were found by something
  breaking, weeks apart.

  ## Why a lint rather than a refactor

  The six copies work. Collapsing them means the harness reading the server's
  module at compile time, which is a real coupling to take on for a list that
  changes once a year. What was missing was not a shared constant — it was any
  way to notice the day they stop agreeing.

  Same reasoning as `HarnessProjectChannel.contract_version/0`, which is public
  so a test can compare it against the harness's copy: "hardcoding either number
  in a test would assert `1 == 1` and keep passing after somebody bumped one
  side and forgot the other."

  ## Why this discovers rather than lists

  A test that named the six modules would be a seventh copy of the same list,
  and would go stale the same way. It scans `lib/` for enumerations that mention
  the analyzer sources and checks each against the canonical set, so a *new*
  module that grows its own copy is caught the day it appears.

  Divergences that are correct are exempted by name with the reason, following
  `ReleaseSafetyTest`'s convention that an exemption list is a lint exemption
  and not a safety claim.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Run

  @lib_root Path.expand("../../lib", __DIR__)

  # Attribute names whose value enumerates analyzer sources. Matched by name so
  # an unrelated `@sources` is not dragged in; the content check below decides
  # whether it is really about this domain.
  @names ~w(
    sources valid_sources all_sources source_cost cost
    subprocess_analyzers config_gated_analyzers configurable_sources
    source_roles role_analyzers analyzers
  )

  @attr ~r/^\s*@(#{Enum.join(@names, "|")})\s+(~w\([^)]*\)|\[[^\]]*\]|%\{[^}]*\})/m

  # Enumerations that legitimately omit a source, and which one, and why.
  #
  # A lint exemption rather than a claim that the two agree — the same
  # convention `ReleaseSafetyTest` states for its own list.
  @exempt %{
    # Compiler is not a subprocess analyzer: `run_pipeline/5` adds it separately
    # (`["compiler" | enabled]`) because it runs whatever the per-source config
    # says.
    "code_my_spec/validation.ex" => ~w(compiler),
    # Neither compiler nor spex is config-gated — compiler always runs, and spex
    # runs whatever its mode, because the specs-passing gate needs a current run
    # to exist. See `@config_gated_analyzers`' own note.
    "code_my_spec/static_analysis/pipeline.ex" => ~w(compiler spex),
    # Not analyzer sources at all — test *database partitions*, which share the
    # names because the two suites that own one are named after the source that
    # schedules them. Compiler and credo run no tests, so they have no database
    # to migrate, and listing them here would name partitions that do not exist.
    "mix/tasks/cms.migrate_test_partitions.ex" => ~w(compiler credo)
  }

  defp canonical, do: MapSet.new(Run.sources())

  # Every atom or string the body mentions, on either side of a map.
  #
  # The sources are not consistently on one side. `@source_roles` keys by source
  # (`%{compiler: [...]}`); `@subprocess_analyzers` keys by *analyzer* and puts
  # the source in the value (`%{spex_stale: "spex"}`). Reading only keys misses
  # the second, only values misses the first.
  #
  # Reading both is safe because of the rule below: a canonical source *missing*
  # is the defect, and extra tokens are not. Every instance of this class was
  # something forgotten — an analyzer added to five of six lists — never
  # something spurious. So `credo_check` and `exunit_stale` coming along for the
  # ride costs nothing.
  defp tokens("~w(" <> rest),
    do: rest |> String.trim_trailing(")") |> String.split() |> MapSet.new()

  defp tokens(body),
    do: MapSet.new(Regex.scan(~r/[:"]([a-z_][a-zA-Z0-9_]*)/, body), fn [_, t] -> t end)

  defp enumerations do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      rel = Path.relative_to(path, @lib_root)

      # `Regex.scan/2` drops trailing groups that did not participate, so the
      # body group can be absent. Destructuring a fixed-length list silently
      # matched nothing and the comprehension skipped every enumeration in the
      # tree — a lint that scanned zero files and passed. Caught by breaking a
      # copy on purpose and watching it stay green.
      for match <- Regex.scan(@attr, File.read!(path)) do
        {rel, Enum.at(match, 1), tokens(Enum.at(match, 2, ""))}
      end
    end)
    # Only enumerations that are plausibly about this domain at all.
    |> Enum.filter(fn {_rel, _name, tokens} ->
      MapSet.size(MapSet.intersection(tokens, canonical())) >= 2
    end)
  end

  # The scan is the whole test, so it has to prove it scanned. Its first version
  # matched nothing at all and passed — `Regex.scan/2` truncates trailing
  # non-participating groups, the destructuring pattern matched neither shape,
  # and a lint that examined zero files reported no drift. A floor turns that
  # from silent into loud.
  #
  # Deliberately a floor and not an exact count: a seventh copy appearing is
  # what the test below is for, not a reason for this one to fail.
  @known_enumerations 8

  test "the scan actually finds the enumerations it is meant to check" do
    found = enumerations()

    assert length(found) >= @known_enumerations, """
    Found only #{length(found)} enumerations of the analyzer sources; expected at
    least #{@known_enumerations}.

    Either they were consolidated — good, lower the floor — or the scan stopped
    matching, in which case this test is checking nothing and every drift below
    passes silently. That is how it failed the first time.

    Found: #{inspect(Enum.map(found, fn {rel, name, _} -> "#{rel} @#{name}" end))}
    """
  end

  test "the canonical source list is what everything else is measured against" do
    assert MapSet.equal?(canonical(), MapSet.new(~w(compiler credo exunit spex))), """
    `Run.sources/0` changed. That is allowed — it is the canonical list — but
    every exemption below was written against the old contents and needs
    re-reading before this test is made to pass again.
    """
  end

  test "every enumeration of analyzer sources agrees with Run.sources/0" do
    drifted =
      for {rel, name, tokens} <- enumerations(),
          not exempt_ok?(rel, tokens),
          do: {rel, name, tokens}

    assert drifted == [], """
    These enumerate the analyzer sources and disagree with `Run.sources/0`:

    #{Enum.map_join(drifted, "\n", fn {rel, name, tokens} -> report(rel, name, tokens) end)}

    Canonical: #{inspect(Enum.sort(Run.sources()))}

    If the difference is correct, add the path to @exempt with the reason —
    that is a lint exemption, not a claim that the two agree. If it is not,
    the two have drifted, which is the defect this test exists to catch: a
    source scheduled that nothing reports, or reported that nothing scheduled.
    """
  end

  # Drift is a canonical source this enumeration does not mention. Extra tokens
  # are not drift: they are the other side of a map, or a legitimately wider
  # domain — `ProblemsLive` lists `qa_validation` and `spec_validation`, which
  # produce problems without a ledger run at all.
  defp missing(rel, tokens) do
    allowed = Map.get(@exempt, rel, [])
    canonical() |> MapSet.difference(tokens) |> MapSet.difference(MapSet.new(allowed))
  end

  defp exempt_ok?(rel, tokens), do: MapSet.size(missing(rel, tokens)) == 0

  defp report(rel, name, tokens),
    do: "  #{rel} @#{name}\n    does not mention: #{inspect(Enum.sort(missing(rel, tokens)))}"
end
