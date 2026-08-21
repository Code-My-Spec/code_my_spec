defmodule CodeMySpec.StaticAnalysis.CredoFollowsTheFilesItJudgesTest do
  @moduledoc """
  A source whose findings can block has to be re-runnable by the edits that
  would fix them.

  `@role_analyzers` picks analyzers from the roles of the files a turn changed.
  `bdd_spec` — the role of every `*_spex.exs` file — did not schedule `:credo`,
  while credo analyses those files perfectly happily and files findings against
  them. So the findings blocked and the work that would clear them could not
  refresh the result: an agent writing specs was held by credo findings *on the
  specs it was writing*, and nothing it did while writing them re-ran credo.

  Measured 2026-08-21 on one project: 282 credo findings against `_spex.exs`
  files, byte-identical stop feedback across consecutive stops, the findings
  recorded at 11:10 and the change that cleared them landed at 08:02. Every stop
  in that window enqueued `compiler, spex`; credo was in neither the enqueued nor
  the skipped list, because it was never in the request set at all.

  This is the same failure the comment above `@role_analyzers` already records
  for `:test` and `:exunit_stale` (`ad53f4ed`) — "an agent that fixes the failing
  test is blocked by the same stale finding afterwards, because fixing it is a
  `:test` edit and a `:test` edit does not schedule the suite that would clear
  it". One role over, and found the same way: by an agent stuck in it.

  So this pins the rule rather than the row. Credo reads any Elixir source under
  the roles below; each of them must schedule it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.StaticAnalysis.Pipeline

  # Every role whose files are Elixir that credo will analyse and file findings
  # against. A role added here that does not schedule credo can produce a
  # finding nothing can clear.
  @credo_readable [:implementation, :test, :test_support, :bdd_spec]

  defp analyzers_for(role) do
    # Every gated analyzer on, so this measures the role map rather than a mode.
    Pipeline.resolve_analyzers(nil, [%{role: role}], %{
      credo: :block_all,
      exunit: :block_all,
      spex: :block_all
    })
  end

  for role <- @credo_readable do
    test "#{role} changes schedule credo" do
      assert :credo in analyzers_for(unquote(role)),
             "credo files findings against #{unquote(role)} files, so editing one has " <>
               "to be able to re-run credo. Otherwise its findings block and the edit " <>
               "that would fix them cannot refresh the result."
    end
  end

  # The one this was found through, kept named so the regression is legible.
  test "a spex file still schedules what it already scheduled" do
    analyzers = analyzers_for(:bdd_spec)

    assert :validate_bdd in analyzers
    assert :spex_stale in analyzers
  end

  # Guard against the assertion above passing on an empty list — a role that
  # resolved to nothing would satisfy "does not schedule credo" vacuously if the
  # test were ever inverted, and would satisfy nothing useful now.
  test "a role with no analyzers is distinguishable from one with credo" do
    assert analyzers_for(:architecture) == []
  end
end
