defmodule CodeMySpec.Analysis.SignaturesTest do
  @moduledoc """
  The record that lets one sweep be compared against the one before it.

  `problems` are replaced per run and carry no run id, so what the previous
  sweep found is gone the moment the next one finishes. `08d3f858`: a
  resolution was written on this project claiming "zero problems matching the
  signature, where the prior sweep carried the leak" — against a baseline
  nobody had checked and which no longer existed. Unfalsifiable at the moment
  it was made, which is why it went in unchallenged.

  So the assertions here are about the two things that would let that happen
  again: that a comparison which never happened is not reported as one, and
  that a capped list does not read as findings having disappeared.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.{Run, Signatures}

  defp problem(attrs) do
    Enum.into(attrs, %{file_path: "lib/a.ex", line: 1, message: "boom"})
  end

  defp run_with(signatures) do
    %Run{stats: Signatures.put(%{}, signatures)}
  end

  describe "of/1" do
    test "identifies a finding by file, line and message head" do
      assert ["lib/a.ex:12 boom"] =
               Signatures.of([problem(file_path: "lib/a.ex", line: 12, message: "boom")])
    end

    test "sorts, so two runs' lists compare directly regardless of insertion order" do
      forwards =
        Signatures.of([
          problem(file_path: "lib/b.ex"),
          problem(file_path: "lib/a.ex")
        ])

      backwards =
        Signatures.of([
          problem(file_path: "lib/a.ex"),
          problem(file_path: "lib/b.ex")
        ])

      assert forwards == backwards
    end

    test "collapses findings that share a file, line and message head" do
      assert length(Signatures.of([problem([]), problem([])])) == 1
    end

    test "flattens whitespace, so a multi-line message stays one signature" do
      [signature] = Signatures.of([problem(message: "first line\n   second line")])

      assert signature == "lib/a.ex:1 first line second line"
    end

    test "survives a problem with no line" do
      assert [_signature] = Signatures.of([problem(line: nil)])
    end
  end

  describe "put/1 and read/1" do
    test "round-trips through a run's stats" do
      signatures = Signatures.of([problem([])])

      assert Signatures.read(run_with(signatures)) == signatures
    end

    test "keeps whatever the runner already put in stats" do
      stats = Signatures.put(%{"duration_ms" => 12}, ["lib/a.ex:1 boom"])

      assert stats["duration_ms"] == 12
    end

    test "tolerates a runner that recorded no stats at all" do
      assert %{} = Signatures.put(nil, [])
    end

    test "reads a run that predates signature recording as having none" do
      assert Signatures.read(%Run{stats: %{"duration_ms" => 12}}) == []
      assert Signatures.read(%Run{stats: nil}) == []
      assert Signatures.read(nil) == []
    end
  end

  describe "delta/2" do
    test "names what went away and what arrived, rather than counting" do
      previous = run_with(["lib/a.ex:1 gone", "lib/b.ex:2 stays"])

      assert %{gone: ["lib/a.ex:1 gone"], new: ["lib/c.ex:3 fresh"]} =
               Signatures.delta(previous, ["lib/b.ex:2 stays", "lib/c.ex:3 fresh"])
    end

    test "is empty both ways when nothing moved" do
      assert %{gone: [], new: []} =
               Signatures.delta(run_with(["lib/a.ex:1 boom"]), ["lib/a.ex:1 boom"])
    end
  end

  describe "delta_suffix/2" do
    # The failure this whole module exists to prevent is a comparison being
    # claimed that never happened. A run with no recorded baseline must say
    # nothing, not "0 gone, 0 new" — which asserts the previous sweep found
    # exactly this, on no evidence.
    test "says nothing when there is no baseline to compare against" do
      assert Signatures.delta_suffix(nil, ["lib/a.ex:1 boom"]) == ""
      assert Signatures.delta_suffix(%Run{stats: nil}, ["lib/a.ex:1 boom"]) == ""
    end

    test "distinguishes an unchanged sweep from an absent baseline" do
      assert Signatures.delta_suffix(run_with(["lib/a.ex:1 boom"]), ["lib/a.ex:1 boom"]) =~
               "unchanged"
    end

    test "counts both directions when findings moved" do
      suffix = Signatures.delta_suffix(run_with(["lib/a.ex:1 old"]), ["lib/b.ex:2 new"])

      assert suffix =~ "1 gone"
      assert suffix =~ "1 new"
    end
  end

  describe "the cap" do
    # A truncated list that reported its own length would understate the run and
    # read as findings having vanished — the exact misreading this module exists
    # to prevent, reintroduced by its own storage bound.
    test "records the true count of what it stored, and bounds the list" do
      problems = for n <- 1..500, do: problem(line: n)

      signatures = Signatures.of(problems)
      stats = Signatures.put(%{}, signatures)

      assert length(signatures) == 400
      assert stats["problem_signature_count"] == 400
    end
  end
end
