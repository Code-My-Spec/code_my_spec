defmodule CodeMySpec.Validation.SupersededFindingsTest do
  @moduledoc """
  A finding whose source is stale *and* re-running does not block.

  `23c8e006`. The stop response said two things that could not both be
  satisfied: "Fix these problems before stopping", and four lines down, "do not
  re-fix anything you have already corrected — a rerun is in flight, stop again
  and let it replace these". Stopping as instructed re-served the same payload.

  Reported twice, and the second occurrence is the one that decides the design.
  The first had a failing rerun (2m32s then 2m53s against a typical 1m7s, under
  a concurrent provisioning drill), so it looked like a job for "surface the
  rerun's failure". The second had a *healthy* rerun — "15s of a typical 19s",
  no channel drop, no rejected result — findings already fixed on disk, the
  analyzer agreeing (422 findings project-wide, zero in that file, instrument
  checked against the same rules still firing elsewhere), and stale line
  numbers pointing at unrelated code. There was no failure to surface. The
  block was the lag itself.

  Both conditions are load-bearing, which is what these tests are mostly about:
  a stale source with nothing running still blocks, because that is a real
  finding nobody is measuring and waiting cannot help — that case is
  `cc1016a8`, and hiding it here would have buried it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Validation

  defp problem(source), do: %Problem{source: source, severity: :error, file_path: "a.ex", line: 1}

  describe "split_superseded/3" do
    test "demotes a finding whose source is stale and re-running" do
      {blocking, superseded} =
        Validation.split_superseded([problem("credo")], ["credo"], ["credo"])

      assert blocking == []
      assert [%Problem{source: "credo"}] = superseded
    end

    # The distinction this whole change rests on. Stale with nothing running is
    # a finding no rerun will replace, and demoting it would turn the gate off
    # for exactly the case that needs it.
    test "keeps a stale finding when nothing is running" do
      {blocking, superseded} = Validation.split_superseded([problem("credo")], ["credo"], [])

      assert [%Problem{source: "credo"}] = blocking
      assert superseded == []
    end

    # A run in flight for a source that is already current says nothing about
    # findings that are themselves current.
    test "keeps a fresh finding even while its source re-runs" do
      {blocking, superseded} = Validation.split_superseded([problem("credo")], [], ["credo"])

      assert [%Problem{source: "credo"}] = blocking
      assert superseded == []
    end

    test "demotes only the sources in both sets" do
      findings = [problem("credo"), problem("exunit"), problem("spex")]

      {blocking, superseded} =
        Validation.split_superseded(findings, ["credo", "exunit"], ["credo", "spex"])

      assert Enum.map(blocking, & &1.source) |> Enum.sort() == ["exunit", "spex"]
      assert Enum.map(superseded, & &1.source) == ["credo"]
    end

    test "passes everything through when nothing is stale or running" do
      findings = [problem("credo"), problem("exunit")]

      assert {^findings, []} = Validation.split_superseded(findings, [], [])
    end
  end
end
